import 'dart:async';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';
import '../shared/human_error.dart';
import '../services/push_dispatch_service.dart';
import '../services/push_error_logger.dart';
import '../services/notification_service.dart';
import '../services/learner_notification_settings_service.dart';
import '../services/audit_action_keys.dart';
import '../services/audit_log_service.dart';
import '../services/secure_window_service.dart';
import '../shared/app_feedback.dart';
import '../shared/app_theme.dart';
import '../shared/watermark_background.dart';
import '../shared/ybs_busy_logo.dart';
import '../shared/learner_web_layout.dart';
import '../shared/payment_status.dart';
import '../shared/profile_avatar.dart';
import '../shared/learner_notice_popup.dart';

class LearnerBookingScreen extends StatefulWidget {
  const LearnerBookingScreen({super.key, this.courseId});

  /// Pass a REAL courseId (recommended).
  final String? courseId;

  @override
  State<LearnerBookingScreen> createState() => _LearnerBookingScreenState();
}

class _LearnerBookingScreenState extends State<LearnerBookingScreen>
    with SingleTickerProviderStateMixin {
  // ===== Colors =====
  static const primaryBlue = Color(0xFF0E7C86);
  static const actionOrange = Color(0xFFBF5D39);
  static const uiBorder = Color(0xFFD8CFC1);

  // Simplified status colors
  static const peerBg = Color(0xFFE9F4FF);
  static const peerBorder = Color(0xFF9BC8FF);
  static const bookedBg = Color(0xFFEAF7EE);
  static const bookedBorder = Color(0xFFB9E2C5);
  static const otherSessionBg = Color(0xFFF1F3F5);
  static const otherSessionBorder = Color(0xFFCED4DA);
  static const switchSessionBg = Color(0xFFEAF6FF);
  static const switchSessionBorder = Color(0xFF9FD4F5);
  static const exactMatchBg = Color(0xFFE7F8ED);
  static const exactMatchBorder = Color(0xFF1F8A49);
  static const emptyBg = Color(0xFFFFF1E3);
  static const emptyBorder = Color(0xFFF9C59D);
  static const lockedBg = Color(0xFFFEE2E2);
  static const lockedBorder = Color(0xFFF87171);

  AppPalette get palette => appThemeController.palette;

  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  // Auth
  String _authUid = '';
  String myUid = '';
  bool loading = true;
  bool booking = false;
  bool refreshing = false;
  bool _bookingCancelled = false;
  String progressLabel = '';

  // Course
  String? courseId;
  String courseTitle = '';

  // Curriculum (optional)
  int totalSessions = 0;
  Map<String, dynamic> curriculumSessions = {};
  List<Map<String, dynamic>> curriculumUnits = [];

  // Progress
  int currentSession = 1;
  int studiedSessionsConsumed = 0;

  String studyMode = 'follow'; // follow | custom
  int selectedSessionNo = 1;
  bool lessonsExpanded = false;

  // Slots window / schedule
  int daysAhead = 14;
  List<_Slot> generatedSlots = [];

  // My bookings map: "yyyy-mm-dd|HH:MM|teacherId" -> sessionNo
  Map<String, int> myBookedSlots = {};

  // Slot group summary: "yyyy-mm-dd|HH:MM|teacherId" -> summary
  Map<String, _SlotSummary> slotSummary = {};
  Map<String, _GlobalSlotOccupancy> globalSlotOccupancy = {};
  Map<String, String> courseTitleById = {};

  // UI state
  _BookingFlowStep flowStep = _BookingFlowStep.lessonChoice;
  DateTime? selectedDay;
  String? selectedTime;
  String? selectedTeacherId;
  _SchedulePath schedulePath = _SchedulePath.byTeacher;
  String? selectedTeacherFirstId;
  int? selectedLessonForFlow;
  int? confirmSessionNo;
  bool confirmSessionExpanded = false;
  String? _lastBookedStudyMode;
  int _computedRecommendedSessionNo = 1;
  int upcomingBookingsCount = 0;
  String helpLang = 'ar'; // en | ar | fr | tr | ur
  bool lessonChoiceArabic = true;
  final Set<String> _expandedSyllabusObjectives = <String>{};
  late final AnimationController _sessionPulseCtrl;
  Map<String, List<_BusyRange>>? _busyRangesCache;
  DateTime? _busyRangesCacheAt;
  static const Duration _busyRangesCacheTtl = Duration(seconds: 25);
  DateTime? _busyVisualSince;
  final Map<String, _TeacherMiniProfile> _teacherMiniCache = {};
  final Map<String, _TeacherFullProfile> _teacherFullCache = {};
  final Map<String, DateTime> _teacherFullCacheAt = {};
  final Map<String, Future<_TeacherFullProfile>> _teacherFullInFlight = {};
  static const Duration _teacherFullCacheTtl = Duration(minutes: 5);
  final ScrollController _pageScrollCtrl = ScrollController();
  final GlobalKey _byTeacherSelectionKey = GlobalKey();
  final GlobalKey _timeStepKey = GlobalKey();
  final GlobalKey _teacherStepKey = GlobalKey();
  String? _appliedRecommendationKey;
  bool _teachersCollapsed = false;
  bool _teachersCollapseTouched = false;

  @override
  void initState() {
    super.initState();
    appThemeController.addListener(_onThemeChanged);
    _sessionPulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 980),
    )..repeat(reverse: true);
    _init();
  }

  @override
  void dispose() {
    appThemeController.removeListener(_onThemeChanged);
    _sessionPulseCtrl.dispose();
    _pageScrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _applyRecommendedSlot(_Slot s) async {
    setState(() {
      _appliedRecommendationKey = s.key;
      schedulePath = _SchedulePath.byTeacher;
      _teachersCollapsed = true;
      selectedTeacherFirstId = s.teacherId;
      selectedTeacherId = s.teacherId;
      selectedDay = DateTime(s.start.year, s.start.month, s.start.day);
      selectedTime = s.time;
    });
  }

  bool _goBackOneStepInFlow() {
    if (progressLabel.isNotEmpty) {
      _showCancelBookingDialog();
      return true;
    }
    switch (flowStep) {
      case _BookingFlowStep.success:
        setState(() => flowStep = _BookingFlowStep.confirm);
        return true;
      case _BookingFlowStep.confirm:
        setState(() => flowStep = _BookingFlowStep.schedule);
        return true;
      case _BookingFlowStep.schedule:
        setState(() => flowStep = _BookingFlowStep.lessonChoice);
        return true;
      case _BookingFlowStep.lessonChoice:
        return false;
    }
  }

  void _showCancelBookingDialog() {
    final isAr = lessonChoiceArabic;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Text(
          isAr ? 'الحجز قيد التنفيذ' : 'Booking in progress',
          style: const TextStyle(fontWeight: FontWeight.w900),
        ),
        content: Text(
          isAr
              ? 'يتم معالجة حجزك. هل تريد إلغاء الحجز والعودة؟'
              : 'Your booking is being processed. Cancel and go back?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(isAr ? 'الانتظار' : 'Keep waiting'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFB91C1C),
            ),
            onPressed: () {
              _bookingCancelled = true;
              setState(() => progressLabel = '');
              _clearBusyVisualIfIdle();
              Navigator.pop(ctx);
            },
            child: Text(
              isAr ? 'إلغاء الآن' : 'Cancel now',
              style: const TextStyle(fontWeight: FontWeight.w900),
            ),
          ),
        ],
      ),
    );
  }

  void _scrollTo(GlobalKey key) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = key.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          alignment: 0.15,
          duration: const Duration(milliseconds: 350),
        );
      }
    });
  }

  bool _isAtEntryStep() => flowStep == _BookingFlowStep.lessonChoice;

  void _onThemeChanged() {
    if (!mounted) return;
    setState(() {});
  }

  // ================== Helpers ==================

  void _toast(String msg) {
    if (!mounted) return;
    unawaited(
      showLearnerNoticePopup(
        context,
        message: msg,
        tone: learnerNoticeToneForMessage(msg),
      ),
    );
  }

  Future<bool> _confirmWithLogo({
    required String title,
    required String message,
    required String confirmLabel,
    Color confirmColor = primaryBlue,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        titlePadding: const EdgeInsets.fromLTRB(18, 16, 18, 0),
        title: Row(
          children: [
            const YbsBusyLogo(size: 32),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
            ),
          ],
        ),
        content: Text(message, style: const TextStyle(height: 1.35)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('No'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: confirmColor),
            onPressed: () => Navigator.pop(context, true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return result == true;
  }

  String _two(int n) => n < 10 ? '0$n' : '$n';

  String _dateKey(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';

  String _weekdayKey(DateTime d) {
    switch (d.weekday) {
      case DateTime.monday:
        return 'mon';
      case DateTime.tuesday:
        return 'tue';
      case DateTime.wednesday:
        return 'wed';
      case DateTime.thursday:
        return 'thu';
      case DateTime.friday:
        return 'fri';
      case DateTime.saturday:
        return 'sat';
      default:
        return 'sun';
    }
  }

  int _toInt(dynamic v, {int fallback = 0}) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? fallback;
  }

  bool _toBool(dynamic v, {bool fallback = false}) {
    if (v is bool) return v;
    final s = (v ?? '').toString().trim().toLowerCase();
    if (s == 'true' || s == '1' || s == 'yes') return true;
    if (s == 'false' || s == '0' || s == 'no') return false;
    return fallback;
  }

  Map<String, dynamic> _asStringKeyMap(dynamic value) {
    if (value is! Map) return const <String, dynamic>{};
    final out = <String, dynamic>{};
    value.forEach((k, v) {
      out[k.toString()] = v;
    });
    return out;
  }

  int _readSessionNoFromProgress(dynamic raw) {
    if (raw == null) return 0;

    if (raw is Map) {
      final m = _asStringKeyMap(raw);
      final direct = _toInt(m['currentSession'], fallback: 0);
      if (direct > 0) return direct;

      if (m.length == 1) {
        return _readSessionNoFromProgress(m.values.first);
      }
      return 0;
    }

    return _toInt(raw, fallback: 0);
  }

  int get _effectiveTotalSessions {
    if (totalSessions > 0) return totalSessions;
    if (curriculumSessions.isNotEmpty) return curriculumSessions.length;
    return currentSession > 0 ? currentSession : 1;
  }

  int get _targetSessionNo {
    final maxSessions = _effectiveTotalSessions;
    final explicit = selectedLessonForFlow;
    if (explicit != null) return explicit.clamp(1, maxSessions).toInt();

    if (studyMode == 'custom') {
      return selectedSessionNo.clamp(1, maxSessions).toInt();
    }

    return _recommendedSessionNo.clamp(1, maxSessions).toInt();
  }

  int get _recommendedSessionNo {
    final maxSessions = _effectiveTotalSessions;
    final raw = _computedRecommendedSessionNo;
    return raw.clamp(1, maxSessions).toInt();
  }

  Future<void> _recomputeRecommendedSessionNo(String cid) async {
    final maxSessions = _effectiveTotalSessions;
    var base = currentSession.clamp(1, maxSessions).toInt();

    final upcoming = await _findMyUpcomingBookings(cid);
    final bookedSessions = upcoming
        .map((b) => b.sessionNo)
        .where((n) => n > 0)
        .toSet();

    var highestBooked = 0;
    for (final n in bookedSessions) {
      if (n > highestBooked) highestBooked = n;
    }

    var candidate = highestBooked > 0 ? (highestBooked + 1) : base;
    if (candidate < base) candidate = base;
    if (candidate > maxSessions) candidate = maxSessions;

    while (bookedSessions.contains(candidate) && candidate < maxSessions) {
      candidate++;
    }

    if (candidate < base) candidate = base;
    if (candidate > maxSessions) candidate = maxSessions;

    if (!mounted) return;
    setState(() {
      _computedRecommendedSessionNo = candidate;
      if (studyMode == 'follow') {
        selectedSessionNo = candidate;
      }
    });
  }

  DatabaseReference _availabilityRootRef() => _db.child('booking_availability');

  DatabaseReference _progressRef(String cid) =>
      _db.child('booking_progress/$myUid/$cid');

  DatabaseReference _reservationsRootRef(String cid) =>
      _db.child('booking_reservations/$cid');

  DatabaseReference _legacyReservationsRef(
    String cid,
    String dayKey,
    String hhmm,
  ) => _db.child('booking_reservations/$cid/$dayKey/$hhmm');

  DatabaseReference _reservationsRef(
    String cid,
    String dayKey,
    String hhmm,
    String teacherId,
  ) => _db.child('booking_reservations/$cid/$dayKey/$hhmm/$teacherId');

  String _slotSummaryKey(String dayKey, String hhmm, String teacherId) =>
      '$dayKey|$hhmm|$teacherId';

  String _bookingKey(String courseId, String dayKey, String hhmm) =>
      '$courseId|$dayKey|$hhmm';

  Future<String> _resolveLearnerUidFromAuth(String authUid) async {
    final clean = authUid.trim();
    if (clean.isEmpty) return '';
    try {
      final snap = await _db.child('users/$clean').get();
      if (snap.value is Map) {
        final m = (snap.value as Map).map((k, v) => MapEntry(k.toString(), v));
        final canonical = (m['uid'] ?? '').toString().trim();
        if (canonical.isNotEmpty) return canonical;
      }
    } catch (_) {}
    return clean;
  }

  String _bilingual(String en, String ar) => '$en\n$ar';

  String _cancelCardTitle() =>
      lessonChoiceArabic ? 'إلغاء حجز' : 'Cancel a booking';

  String _cancelCardSubtitle() => lessonChoiceArabic
      ? 'افتح حصصك القادمة وقم بالإلغاء إذا كان مسموحًا'
      : 'Open your upcoming classes and cancel if eligible';

  String _cancelSheetTitle() =>
      lessonChoiceArabic ? 'إلغاء الحصص المحجوزة' : 'Cancel Booked Classes';

  String _cancelSheetEmpty() => lessonChoiceArabic
      ? 'لا توجد حجوزات قادمة للإلغاء.'
      : 'No upcoming bookings to cancel.';

  String _cancelLockedLabel() =>
      lessonChoiceArabic ? 'مغلق (أقل من 24 ساعة)' : 'Locked (<24h)';

  String _cancelActionLabel() => lessonChoiceArabic ? 'إلغاء' : 'Cancel';

  String _cancelDetailsLabel(bool expanded) => lessonChoiceArabic
      ? (expanded ? 'إخفاء التفاصيل' : 'تفاصيل الحصة')
      : (expanded ? 'Hide details' : 'Session details');

  String _cancelObjectiveLabel() =>
      lessonChoiceArabic ? 'هدف الحصة' : 'Session objective';

  String _cancelNoObjectiveLabel() => lessonChoiceArabic
      ? 'لا يوجد وصف متاح لهذه الحصة.'
      : 'No objective available for this session.';

  String _confirmObjectiveLabel() =>
      lessonChoiceArabic ? 'هدف الحصة' : 'Session objective';

  String _bookingLimitNote() => lessonChoiceArabic
      ? 'لقد حجزت 3 دروس بالفعل. ألغِ واحدة للمتابعة.'
      : 'You already booked 3 sessions. Cancel one to continue.';

  Future<bool> _hasPossibleMissingAttendanceForSession({
    required String cid,
    required int sessionNo,
  }) async {
    if (sessionNo <= 0) return false;

    final now = DateTime.now();
    final cutoff = now.subtract(const Duration(hours: 2));
    const lookbackDays = 35;

    final attendanceByKey = <String, dynamic>{};
    try {
      final attSnap = await _progressRef(cid).child('online_attendance').get();
      if (attSnap.exists && attSnap.value is Map) {
        final m = (attSnap.value as Map).map(
          (k, v) => MapEntry(k.toString(), v),
        );
        attendanceByKey.addAll(m);
      }
    } catch (_) {}

    bool hasMissingForBooking(String dayKey, String hhmm) {
      final bKey = _bookingKey(cid, dayKey, hhmm);
      final rec = attendanceByKey[bKey];
      if (rec is! Map) return true;
      return false;
    }

    try {
      for (int i = 1; i <= lookbackDays; i++) {
        final day = DateTime(
          now.year,
          now.month,
          now.day,
        ).subtract(Duration(days: i));
        final dayKey = _dateKey(day);

        final daySnap = await _reservationsRootRef(cid).child(dayKey).get();
        if (!daySnap.exists || daySnap.value is! Map) continue;

        final byTime = (daySnap.value as Map).map(
          (k, v) => MapEntry(k.toString(), v),
        );

        for (final timeEntry in byTime.entries) {
          final hhmm = timeEntry.key;
          final timeNode = timeEntry.value;
          if (timeNode is! Map) continue;

          final start = _parseSlotStart(dayKey, hhmm);
          if (start == null || start.isAfter(cutoff)) continue;

          final m = timeNode.map((k, v) => MapEntry(k.toString(), v));

          bool matchesSlot(Map<dynamic, dynamic> slotNode) {
            final sm = slotNode.map((k, v) => MapEntry(k.toString(), v));
            final learnersRaw = sm['learners'];
            if (learnersRaw is! Map) return false;

            final learners = learnersRaw.map(
              (k, v) => MapEntry(k.toString(), v),
            );
            if (!learners.containsKey(myUid)) return false;

            final sNo = _toInt(sm['sessionNo'], fallback: 0);
            return sNo == sessionNo;
          }

          if (m['learners'] is Map) {
            if (matchesSlot(m) && hasMissingForBooking(dayKey, hhmm)) {
              return true;
            }
            continue;
          }

          for (final teacherEntry in m.entries) {
            final teacherNode = teacherEntry.value;
            if (teacherNode is! Map) continue;
            if (matchesSlot(teacherNode) &&
                hasMissingForBooking(dayKey, hhmm)) {
              return true;
            }
          }
        }
      }
    } catch (_) {}

    return false;
  }

  Future<bool?> _askSessionCheckBeforeBooking(int sessionNo) {
    return showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text('Session check'),
        content: Text(
          'You may have already attended Session $sessionNo, but attendance is not confirmed yet.\n\n'
          'You can restudy this session, or choose another session manually.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, null),
            child: const Text('Cancel'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Choose another'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Restudy this'),
          ),
        ],
      ),
    );
  }

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
        return DateTime.monday;
    }
  }

  String _busyKey(String teacherId, String dayKey) => '$teacherId|$dayKey';

  bool _hasTimeOverlap({
    required DateTime aStart,
    required DateTime aEnd,
    required DateTime bStart,
    required DateTime bEnd,
  }) {
    return aStart.isBefore(bEnd) && bStart.isBefore(aEnd);
  }

  String _readClassTeacherUid(Map<String, dynamic> classData) {
    final direct = [
      classData['teacherUid'],
      classData['teacher_uid'],
      classData['teacherId'],
      classData['teacher_id'],
      classData['instructorUid'],
      classData['instructor_uid'],
    ];

    for (final raw in direct) {
      final s = (raw ?? '').toString().trim();
      if (s.isNotEmpty) return s;
    }

    final current = classData['instructor_current'];
    if (current is Map) {
      final cm = current.map((k, v) => MapEntry(k.toString(), v));
      final fromCurrent =
          (cm['uid'] ?? cm['teacher_uid'] ?? cm['teacherId'] ?? cm['id'] ?? '')
              .toString()
              .trim();
      if (fromCurrent.isNotEmpty) return fromCurrent;
    }

    return '';
  }

  Future<Map<String, List<_BusyRange>>>
  _loadTeacherBusyRangesForWindow() async {
    final nowForCache = DateTime.now();
    if (_busyRangesCache != null && _busyRangesCacheAt != null) {
      final age = nowForCache.difference(_busyRangesCacheAt!);
      if (age <= _busyRangesCacheTtl) {
        return _busyRangesCache!;
      }
    }

    final now = DateTime.now();
    final startOfToday = DateTime(now.year, now.month, now.day);
    final endOfWindow = startOfToday.add(Duration(days: daysAhead));

    final out = <String, List<_BusyRange>>{};

    try {
      final snap = await _db.child('classes').get();
      if (!snap.exists || snap.value is! Map) return out;

      final root = (snap.value as Map).map((k, v) => MapEntry(k.toString(), v));

      for (final entry in root.entries) {
        final raw = entry.value;
        if (raw is! Map) continue;

        final cls = raw.map((k, v) => MapEntry(k.toString(), v));
        final status = (cls['status'] ?? '').toString().trim().toLowerCase();
        if (status != 'active') continue;

        final teacherId = _readClassTeacherUid(cls);
        if (teacherId.isEmpty) continue;

        final schedule = cls['schedule'];
        if (schedule is! Map) continue;
        final sm = schedule.map((k, v) => MapEntry(k.toString(), v));

        final firstRaw = (sm['first_session_date'] ?? '').toString().trim();
        final firstDate = DateTime.tryParse(firstRaw);
        final firstDay = firstDate == null
            ? startOfToday
            : DateTime(firstDate.year, firstDate.month, firstDate.day);

        final sessionsRaw = sm['sessions'];
        final rows = <Map<String, dynamic>>[];
        if (sessionsRaw is List) {
          for (final item in sessionsRaw) {
            if (item is! Map) continue;
            rows.add(item.map((k, v) => MapEntry(k.toString(), v)));
          }
        } else if (sessionsRaw is Map) {
          for (final item in sessionsRaw.values) {
            if (item is! Map) continue;
            rows.add(item.map((k, v) => MapEntry(k.toString(), v)));
          }
        }
        if (rows.isEmpty) continue;

        for (int i = 0; i < daysAhead; i++) {
          final day = startOfToday.add(Duration(days: i));
          if (day.isBefore(firstDay)) continue;

          final dayKey = _dateKey(day);
          for (final row in rows) {
            final weekday = _weekdayFromShort((row['day'] ?? '').toString());
            if (weekday != day.weekday) continue;

            final hm = (row['start_time'] ?? '').toString().trim().split(':');
            if (hm.length != 2) continue;

            final h = int.tryParse(hm[0]);
            final m = int.tryParse(hm[1]);
            if (h == null || m == null) continue;
            if (h < 0 || h > 23 || m < 0 || m > 59) continue;

            final start = DateTime(day.year, day.month, day.day, h, m);
            if (!start.isBefore(endOfWindow)) continue;

            final duration = _toInt(row['duration_min'], fallback: 60);
            final safeDuration = duration > 0 ? duration : 60;
            final end = start.add(Duration(minutes: safeDuration));

            final key = _busyKey(teacherId, dayKey);
            out
                .putIfAbsent(key, () => <_BusyRange>[])
                .add(_BusyRange(start: start, end: end));
          }
        }
      }
    } catch (_) {}

    _busyRangesCache = out;
    _busyRangesCacheAt = DateTime.now();
    return out;
  }

  void _invalidateBusyRangesCache() {
    _busyRangesCache = null;
    _busyRangesCacheAt = null;
  }

  bool _hasClassConflict(
    Map<String, List<_BusyRange>> busyByTeacherDay,
    String teacherId,
    DateTime slotStart,
    int slotDurationMinutes,
  ) {
    final dayKey = _dateKey(slotStart);
    final busy = busyByTeacherDay[_busyKey(teacherId, dayKey)] ?? const [];
    if (busy.isEmpty) return false;

    final slotDuration = slotDurationMinutes > 0 ? slotDurationMinutes : 60;
    final slotEnd = slotStart.add(Duration(minutes: slotDuration));
    for (final b in busy) {
      if (_hasTimeOverlap(
        aStart: slotStart,
        aEnd: slotEnd,
        bStart: b.start,
        bEnd: b.end,
      )) {
        return true;
      }
    }
    return false;
  }

  Future<String> _loadTeacherProfileMeetUrl(String teacherId) async {
    final id = teacherId.trim();
    if (id.isEmpty) return '';
    try {
      final snap = await _db.child('users/$id/google_meet_url').get();
      return (snap.value ?? '').toString().trim();
    } catch (_) {
      return '';
    }
  }

  Future<_TeacherMiniProfile> _loadTeacherMiniProfile(String teacherId) async {
    final id = teacherId.trim();
    if (id.isEmpty) {
      return const _TeacherMiniProfile(
        name: 'Teacher',
        photoUrl: '',
        hasIntroVideo: false,
      );
    }
    final hit = _teacherMiniCache[id];
    if (hit != null) return hit;
    try {
      final snap = await _db.child('users/$id').get();
      if (snap.exists && snap.value is Map) {
        final m = (snap.value as Map).map((k, v) => MapEntry(k.toString(), v));
        final first = (m['first_name'] ?? '').toString().trim();
        final last = (m['last_name'] ?? '').toString().trim();
        final full = '$first $last'.trim();
        final name = full.isEmpty
            ? ((m['email'] ?? 'Teacher').toString().trim())
            : full;
        final out = _TeacherMiniProfile(
          name: name.isEmpty ? 'Teacher' : name,
          photoUrl: ProfileAvatar.resolvePhotoFromMap(m),
          hasIntroVideo: (m['intro_video_url'] ?? '')
              .toString()
              .trim()
              .isNotEmpty,
        );
        _teacherMiniCache[id] = out;
        return out;
      }
    } catch (_) {}
    const fallback = _TeacherMiniProfile(
      name: 'Teacher',
      photoUrl: '',
      hasIntroVideo: false,
    );
    _teacherMiniCache[id] = fallback;
    return fallback;
  }

  Future<_TeacherFullProfile> _loadTeacherFullProfile(String teacherId) async {
    final id = teacherId.trim();
    if (id.isEmpty) return const _TeacherFullProfile();
    final hit = _teacherFullCache[id];
    final hitAt = _teacherFullCacheAt[id];
    if (hit != null &&
        hitAt != null &&
        DateTime.now().difference(hitAt) <= _teacherFullCacheTtl) {
      return hit;
    }
    final inFlight = _teacherFullInFlight[id];
    if (inFlight != null) return inFlight;

    final future = _loadTeacherFullProfileFresh(id);
    _teacherFullInFlight[id] = future;
    try {
      return await future;
    } finally {
      _teacherFullInFlight.remove(id);
    }
  }

  Future<_TeacherFullProfile> _loadTeacherFullProfileFresh(String id) async {
    try {
      final base = _db.child('users/$id');
      final snaps = await Future.wait([
        base.child('about_me').get(),
        base.child('intro_video_url').get(),
        base.child('social_links_visible_to_learners').get(),
        base.child('social_links').get(),
      ]);

      final socialLinks = <String, String>{};
      final rawSocial = snaps[3].value;
      if (rawSocial is Map) {
        rawSocial.forEach((k, v) {
          final key = k.toString().trim().toLowerCase();
          final val = (v ?? '').toString().trim();
          if (key.isNotEmpty && val.isNotEmpty) socialLinks[key] = val;
        });
      }

      final out = _TeacherFullProfile(
        aboutMe: (snaps[0].value ?? '').toString().trim(),
        introVideoUrl: (snaps[1].value ?? '').toString().trim(),
        socialVisible: snaps[2].value != false,
        socialLinks: socialLinks,
      );
      _teacherFullCache[id] = out;
      _teacherFullCacheAt[id] = DateTime.now();
      return out;
    } catch (_) {}
    const fallback = _TeacherFullProfile();
    _teacherFullCache[id] = fallback;
    _teacherFullCacheAt[id] = DateTime.now();
    return fallback;
  }

  void _prefetchTeacherFullProfiles(List<_Slot> slots) {
    if (slots.isEmpty) return;
    final ids = <String>[];
    for (final s in slots) {
      final id = s.teacherId.trim();
      if (id.isEmpty || ids.contains(id)) continue;
      ids.add(id);
      if (ids.length >= 8) break;
    }
    for (final id in ids) {
      unawaited(_loadTeacherFullProfile(id));
    }
  }

  Color _teacherTint(String teacherId) {
    final hash = teacherId.codeUnits.fold<int>(
      0,
      (acc, c) => (acc * 31 + c) & 0x7fffffff,
    );
    final hue = (hash % 360).toDouble();
    return HSLColor.fromAHSL(1, hue, 0.45, 0.93).toColor();
  }

  Future<void> _openTeacherProfileSheet(_Slot s) async {
    final mini =
        _teacherMiniCache[s.teacherId] ??
        _TeacherMiniProfile(
          name: s.teacherName,
          photoUrl: s.teacherPhotoUrl,
          hasIntroVideo: s.hasIntroVideo,
        );
    if (!mounted) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return FutureBuilder<_TeacherFullProfile>(
          future: _loadTeacherFullProfile(s.teacherId),
          builder: (ctx, snap) {
            final full = snap.data;
            final loading = snap.connectionState != ConnectionState.done;
            final links = (full?.socialVisible ?? false)
                ? (full?.socialLinks ?? const <String, String>{})
                : const <String, String>{};
            final socialButtons = <MapEntry<String, String>>[];
            for (final e in links.entries) {
              final key = e.key.trim().toLowerCase();
              String label = '';
              if (key == 'facebook') label = 'Facebook';
              if (key == 'linkedin') label = 'LinkedIn';
              if (key == 'tiktok') label = 'TikTok';
              if (key == 'extra_url') label = 'More';
              if (label.isEmpty) continue;
              socialButtons.add(MapEntry(label, e.value));
            }
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: uiBorder),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          ProfileAvatar(
                            name: mini.name,
                            photoUrl: mini.photoUrl,
                            radius: 26,
                            borderColor: uiBorder,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              mini.name,
                              style: const TextStyle(
                                fontWeight: FontWeight.w900,
                                color: primaryBlue,
                                fontSize: 18,
                              ),
                            ),
                          ),
                          IconButton(
                            onPressed: () => Navigator.of(ctx).pop(),
                            icon: const Icon(Icons.close_rounded),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      if (loading)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: LinearProgressIndicator(minHeight: 3),
                        ),
                      if (!loading && (full?.aboutMe ?? '').isNotEmpty)
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: primaryBlue.withValues(alpha: 0.05),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            full!.aboutMe,
                            style: TextStyle(
                              color: Colors.grey.shade800,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          if (!loading &&
                              (full?.introVideoUrl ?? '').isNotEmpty)
                            OutlinedButton.icon(
                              onPressed: () => _openSecureMiniVideo(
                                url: full!.introVideoUrl,
                                title: 'Teacher Intro',
                              ),
                              icon: const Icon(
                                Icons.play_circle_fill_rounded,
                                size: 18,
                              ),
                              label: const Text('Watch'),
                            ),
                          for (final e in socialButtons)
                            OutlinedButton(
                              onPressed: () => _openExternalLink(
                                e.value,
                                e.key.toLowerCase(),
                              ),
                              child: Text(e.key),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _openExternalLink(String raw, String label) async {
    var url = raw.trim();
    if (url.isEmpty) return;
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
    }
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) _toast('Could not open $label.');
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

  bool _isWithin24Hours(_Slot slot) {
    return !slot.start.isAfter(DateTime.now().add(const Duration(hours: 24)));
  }

  bool _isBookingLockedForNewBooking(_Slot slot) {
    if (_isBookedByMe(slot)) return false;
    if (!_isWithin24Hours(slot)) return false;
    return !_isJoinAllowedWithin24h(slot);
  }

  bool _isJoinAllowedWithin24h(_Slot s) {
    final occ = globalSlotOccupancy[s.key];
    if (occ == null || occ.learnerCount <= 0) return false;
    if (_isSlotFull(s)) return false;
    return occ.courseId == (courseId ?? '').trim();
  }

  int _effectiveBookedCount(_Slot s) {
    final global = globalSlotOccupancy[s.key];
    if (global != null) return global.learnerCount;
    return s.bookedCount;
  }

  int? _effectiveGroupSessionNo(_Slot s) {
    final global = globalSlotOccupancy[s.key];
    if (global != null) return global.sessionNo;
    return s.groupSessionNo;
  }

  bool _isBookedByMe(_Slot s) {
    final global = globalSlotOccupancy[s.key];
    if (global != null) return global.bookedByMe;
    return s.bookedByMe;
  }

  bool _isSlotFull(_Slot s) {
    final cap = s.maxLearnersPerSlot <= 0 ? 6 : s.maxLearnersPerSlot;
    return _effectiveBookedCount(s) >= cap;
  }

  _DaySlotSummary _daySlotSummary(DateTime day, {String? teacherId}) {
    final dk = _dateKey(day);
    final slots = _slotsForCurrentLesson().where((s) {
      if (s.dayKey != dk) return false;
      if (teacherId != null && s.teacherId != teacherId) return false;
      return true;
    }).toList();

    if (slots.isEmpty) return _DaySlotSummary.none;

    var hasAvailable = false;
    var hasGroupJoin = false;

    for (final s in slots) {
      final status = _slotStatus(s, sessionNo: _flowLessonNo);
      if (status == _SlotStatus.availableBook) {
        hasAvailable = true;
      } else if (status == _SlotStatus.joinSameSession ||
          status == _SlotStatus.joinWithSessionChange) {
        hasGroupJoin = true;
      }
    }

    if (hasAvailable) return _DaySlotSummary.available;
    if (hasGroupJoin) return _DaySlotSummary.groupOnly;
    return _DaySlotSummary.none;
  }

  _SlotStatus _slotStatus(_Slot s, {int? sessionNo}) {
    if (_isBookedByMe(s)) return _SlotStatus.booked;

    final currentCourse = (courseId ?? '').trim();
    final targetSession = (sessionNo ?? _targetSessionNo).clamp(
      1,
      _effectiveTotalSessions,
    );
    if (_isWithin24Hours(s) && !_isJoinAllowedWithin24h(s)) {
      return _SlotStatus.closed;
    }
    final occ = globalSlotOccupancy[s.key];
    if (occ == null || occ.learnerCount <= 0) return _SlotStatus.availableBook;
    if (_isSlotFull(s)) return _SlotStatus.unavailable;
    if (occ.courseId != currentCourse) return _SlotStatus.unavailable;
    if (occ.sessionNo == null || occ.sessionNo! <= 0) {
      return _SlotStatus.joinSameSession;
    }
    if (occ.sessionNo == targetSession) return _SlotStatus.joinSameSession;
    return _SlotStatus.joinWithSessionChange;
  }

  bool _isCrossLevelBlocked(_Slot s) {
    final occ = globalSlotOccupancy[s.key];
    if (occ == null || occ.learnerCount <= 0) return false;
    return occ.courseId != (courseId ?? '').trim();
  }

  String _blockedSlotToast(_Slot s) {
    if (_isCrossLevelBlocked(s)) {
      return 'This time is already booked by another level.';
    }
    final status = _slotStatus(s, sessionNo: _flowLessonNo);
    if (status == _SlotStatus.closed) {
      return 'Booking closes 24 hours before class.';
    }
    if (_isSlotFull(s)) {
      return 'This slot is full.';
    }
    if (status == _SlotStatus.booked) {
      return 'You already booked this slot.';
    }
    return 'You can’t join this slot.';
  }

  String _levelLabelForCourseId(String cid) {
    final title = (courseTitleById[cid] ?? cid).trim();
    final m = RegExp(
      r'\b(A0|A1|A2|B1|B2|C1|C2)\b',
      caseSensitive: false,
    ).firstMatch(title);
    if (m != null) return m.group(1)!.toUpperCase();
    final short = title.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (short.length <= 12) return short;
    return short.substring(0, 12);
  }

  String _timeChipLabel(String t, _SlotStatus status, {_Slot? slot}) {
    if (slot == null) return t;
    final occ = globalSlotOccupancy[slot.key];
    if (occ == null) return t;
    final sameCourse = occ.courseId == (courseId ?? '').trim();
    final targetSession = _flowLessonNo;
    final isDifferentSessionSameLevel =
        sameCourse && occ.sessionNo != null && occ.sessionNo != targetSession;
    if (status == _SlotStatus.unavailable && !sameCourse) {
      final level = _levelLabelForCourseId(occ.courseId);
      final session = occ.sessionNo != null && occ.sessionNo! > 0
          ? ' S${occ.sessionNo}'
          : '';
      return '$t • Booked $level$session';
    }
    if (status == _SlotStatus.joinWithSessionChange ||
        isDifferentSessionSameLevel) {
      final level = _levelLabelForCourseId(occ.courseId);
      final session = occ.sessionNo != null && occ.sessionNo! > 0
          ? ' S${occ.sessionNo}'
          : '';
      return '$t • Booked $level$session';
    }
    return t;
  }

  _ChipMatchKind _chipMatchKindForSlot(_Slot slot, {int? targetSession}) {
    final occ = globalSlotOccupancy[slot.key];
    if (occ == null || occ.learnerCount <= 0) return _ChipMatchKind.none;
    if (occ.courseId != (courseId ?? '').trim()) return _ChipMatchKind.none;
    final effective = targetSession ?? _flowLessonNo;
    if (occ.sessionNo != null && occ.sessionNo == effective) {
      return _ChipMatchKind.exact;
    }
    if (occ.sessionNo != null && occ.sessionNo != effective) {
      return _ChipMatchKind.matchDifferentSession;
    }
    return _ChipMatchKind.none;
  }

  String _timeChipDetailsLabel(_Slot slot, {int? targetSession}) {
    final occ = globalSlotOccupancy[slot.key];
    if (occ == null || occ.learnerCount <= 0) return slot.time;
    final cap = slot.maxLearnersPerSlot <= 0 ? 6 : slot.maxLearnersPerSlot;
    final level = _levelLabelForCourseId(occ.courseId);
    final sNo = occ.sessionNo ?? targetSession ?? _flowLessonNo;
    final sTitle = _sessionTitleFor(sNo).trim();
    final sLabel = sTitle.isEmpty ? 'Session $sNo' : 'Session $sNo: $sTitle';
    return '${slot.time} ${occ.learnerCount}/$cap L$level $sLabel';
  }

  void _showSessionMiniDetails(_Slot slot, {int? sessionNo}) {
    final no = (sessionNo ?? _effectiveGroupSessionNo(slot) ?? _flowLessonNo)
        .clamp(1, _effectiveTotalSessions);
    final title = _sessionTitleFor(no).trim();
    final objective = _sessionObjectiveFor(no).trim();
    final occ = globalSlotOccupancy[slot.key];
    final cap = slot.maxLearnersPerSlot <= 0 ? 6 : slot.maxLearnersPerSlot;
    final booked = occ?.learnerCount ?? _effectiveBookedCount(slot);
    final left = (cap - booked) < 0 ? 0 : (cap - booked);
    final level = _levelLabelForCourseId(occ?.courseId ?? slot.courseId);

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 44,
              height: 5,
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: const Color(0xFFDDE4EA),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            Text(
              _detailsTitle(helpLang),
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w900,
                color: primaryBlue,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '${slot.time} • ${_friendlyDate(slot.start)}',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            Text(
              '${_labelLevel(helpLang)} $level • ${_labelSeats(helpLang)} $booked/$cap ($left ${_labelLeft(helpLang)})',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: Colors.grey.shade800,
              ),
            ),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFFF3FAFF),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFC2E6FA)),
              ),
              child: Text(
                title.isEmpty ? 'Session $no' : 'Session $no — $title',
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  color: primaryBlue,
                ),
              ),
            ),
            if (objective.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                objective,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: Colors.grey.shade800,
                  height: 1.3,
                ),
              ),
            ],
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  String _detailsTitle(String lang) {
    switch (lang) {
      case 'ar':
        return 'تفاصيل الدرس';
      case 'fr':
        return 'Détails de session';
      case 'tr':
        return 'Oturum detayları';
      case 'ur':
        return 'سیشن کی تفصیلات';
      default:
        return 'Session details';
    }
  }

  String _labelLevel(String lang) {
    switch (lang) {
      case 'ar':
        return 'المستوى';
      default:
        return 'Level';
    }
  }

  String _labelSeats(String lang) {
    switch (lang) {
      case 'ar':
        return 'المقاعد';
      default:
        return 'Seats';
    }
  }

  String _labelLeft(String lang) {
    switch (lang) {
      case 'ar':
        return 'متبقي';
      default:
        return 'left';
    }
  }

  String _recommendedTitle(String lang) {
    switch (lang) {
      case 'ar':
        return 'مقترح لك';
      default:
        return 'Recommended for you';
    }
  }

  String _bookingScreenTitle() {
    final title = courseTitle.trim();
    final isAr = lessonChoiceArabic;
    if (title.isEmpty) return isAr ? 'احجز حصتك' : 'Book Your Class';
    return isAr ? 'احجز لـ $title' : 'Book for $title';
  }

  List<_Slot> _recommendedMatchSlots() {
    final targetSession = _flowLessonNo;
    final out = _slotsForCurrentLesson().where((s) {
      if (_isBookedByMe(s) || _isSlotFull(s)) return false;
      final kind = _chipMatchKindForSlot(s, targetSession: targetSession);
      return kind == _ChipMatchKind.exact ||
          kind == _ChipMatchKind.matchDifferentSession;
    }).toList();
    out.sort((a, b) {
      final ka = _chipMatchKindForSlot(a, targetSession: targetSession);
      final kb = _chipMatchKindForSlot(b, targetSession: targetSession);
      if (ka != kb) {
        if (ka == _ChipMatchKind.exact) return -1;
        if (kb == _ChipMatchKind.exact) return 1;
      }
      final sa = (_effectiveGroupSessionNo(a) ?? targetSession);
      final sb = (_effectiveGroupSessionNo(b) ?? targetSession);
      final bySession = (sa - targetSession).abs().compareTo(
        (sb - targetSession).abs(),
      );
      if (bySession != 0) return bySession;
      return a.start.compareTo(b.start);
    });
    return out.take(3).toList();
  }

  Widget _collapsedTeachersCard(List<_Slot> teachers) {
    final unique = <String, _Slot>{};
    for (final t in teachers) {
      unique.putIfAbsent(t.teacherId, () => t);
    }
    final people = unique.values.toList();
    final selected = selectedTeacherFirstId == null
        ? <_Slot>[]
        : people.where((t) => t.teacherId == selectedTeacherFirstId).toList();
    final selectedName = selected.isEmpty ? null : selected.first.teacherName;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () {
        setState(() {
          _teachersCollapseTouched = true;
          _teachersCollapsed = false;
        });
      },
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFF5FAFE),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFFCBE6F8)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.groups_2_rounded,
                  color: primaryBlue,
                  size: 18,
                ),
                const SizedBox(width: 6),
                Text(
                  'Teachers (${people.length})',
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    color: primaryBlue,
                  ),
                ),
                const Spacer(),
                const Icon(Icons.expand_more_rounded, color: primaryBlue),
              ],
            ),
            const SizedBox(height: 8),
            LayoutBuilder(
              builder: (context, c) {
                final perRow = (c.maxWidth / 34).floor().clamp(1, 12);
                final visibleCount = perRow * 2;
                final visible = people.take(visibleCount).toList();
                final remaining = people.length - visible.length;
                return Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    ...visible.map(
                      (t) => ProfileAvatar(
                        name: t.teacherName,
                        photoUrl: t.teacherPhotoUrl,
                        radius: 14,
                        borderColor: Colors.white,
                      ),
                    ),
                    if (remaining > 0)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: const Color(0xFFCFE0EE)),
                        ),
                        child: Text(
                          '+$remaining',
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            color: primaryBlue,
                            fontSize: 12,
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
            if (selectedName != null) ...[
              const SizedBox(height: 8),
              Text(
                'Selected: $selectedName',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: Colors.grey.shade800,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  int _hhmmToMinutes(String hhmm) {
    final p = hhmm.split(':');
    if (p.length != 2) return 0;
    final h = int.tryParse(p[0]) ?? 0;
    final m = int.tryParse(p[1]) ?? 0;
    return (h * 60) + m;
  }

  List<_Slot> _suggestedSlotsForTeacherDay() {
    if (selectedDay == null || selectedTeacherFirstId == null) return const [];
    final targetSession = _flowLessonNo;
    final dk = _dateKey(selectedDay!);
    final selectedTimeMins = selectedTime == null
        ? null
        : _hhmmToMinutes(selectedTime!);

    final candidates = _slotsForCurrentLesson().where((s) {
      if (s.dayKey != dk) return false;
      if (s.teacherId == selectedTeacherFirstId) return false;
      if (_isBookedByMe(s)) return false;
      if (_isSlotFull(s)) return false;
      final status = _slotStatus(s, sessionNo: targetSession);
      return status == _SlotStatus.joinSameSession ||
          status == _SlotStatus.joinWithSessionChange;
    }).toList();

    candidates.sort((a, b) {
      final sa = (_effectiveGroupSessionNo(a) ?? targetSession);
      final sb = (_effectiveGroupSessionNo(b) ?? targetSession);
      final bySession = (sa - targetSession).abs().compareTo(
        (sb - targetSession).abs(),
      );
      if (bySession != 0) return bySession;

      if (selectedTimeMins != null) {
        final da = (_hhmmToMinutes(a.time) - selectedTimeMins).abs();
        final db = (_hhmmToMinutes(b.time) - selectedTimeMins).abs();
        final byTimeDistance = da.compareTo(db);
        if (byTimeDistance != 0) return byTimeDistance;
      }

      final byTime = _hhmmToMinutes(a.time).compareTo(_hhmmToMinutes(b.time));
      if (byTime != 0) return byTime;
      return a.teacherName.compareTo(b.teacherName);
    });

    return candidates.take(6).toList();
  }

  Future<bool?> _confirmJoinWithSessionChange({
    required int selectedSession,
    required int groupSession,
    required String levelLabel,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) {
        return Dialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const CircleAvatar(
                      radius: 21,
                      backgroundColor: Color(0xFFE7F3FF),
                      child: Icon(Icons.swap_horiz_rounded, color: primaryBlue),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Join with session change',
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 20,
                          color: Color(0xFF1F2937),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Text(
                  'This slot is already booked by $levelLabel.\nهذا الموعد محجوز بالفعل بواسطة مستوى $levelLabel.',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: Colors.grey.shade800,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 10),
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0.96, end: 1),
                  duration: const Duration(milliseconds: 780),
                  curve: Curves.easeOutBack,
                  builder: (_, scale, child) =>
                      Transform.scale(scale: scale, child: child),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEAF6FF),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: const Color(0xFF9FD4F5),
                        width: 1.3,
                      ),
                    ),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        _sessionPulseChip('Selected: S$selectedSession'),
                        _sessionPulseChip('المحدد: S$selectedSession'),
                        const Icon(
                          Icons.arrow_forward_rounded,
                          color: primaryBlue,
                        ),
                        _sessionPulseChip(
                          'Group: S$groupSession',
                          emphasize: true,
                        ),
                        _sessionPulseChip(
                          'المجموعة: S$groupSession',
                          emphasize: true,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Join this group and switch your booking session to Session $groupSession?\nهل تريد الانضمام إلى هذه المجموعة وتغيير درسك المحجوز إلى الدرس $groupSession؟',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: Colors.grey.shade800,
                    fontSize: 15,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('No / لا'),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: primaryBlue,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text(
                          'Join & Switch Session / انضم وغيّر الدرس',
                          style: TextStyle(fontWeight: FontWeight.w900),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _sessionPulseChip(String text, {bool emphasize = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: emphasize ? const Color(0xFFD9EEFF) : Colors.white,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: emphasize ? const Color(0xFF6CB6EA) : const Color(0xFFC7D2E0),
          width: emphasize ? 1.6 : 1,
        ),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontWeight: emphasize ? FontWeight.w900 : FontWeight.w800,
          color: const Color(0xFF0F3659),
          fontSize: emphasize ? 14 : 13,
        ),
      ),
    );
  }

  bool _isJoinable(_Slot s) {
    final status = _slotStatus(s);
    return status == _SlotStatus.availableBook ||
        status == _SlotStatus.joinSameSession ||
        status == _SlotStatus.joinWithSessionChange ||
        status == _SlotStatus.booked;
  }

  Future<String> _getMyFullName() async {
    try {
      final snap = await _db.child('users/$_authUid').get();
      if (!snap.exists || snap.value is! Map) return 'Learner';

      final m = (snap.value as Map).map((k, v) => MapEntry(k.toString(), v));

      final first = (m['first_name'] ?? '').toString().trim();
      final last = (m['last_name'] ?? '').toString().trim();

      final full = '$first $last'.trim();
      if (full.isNotEmpty) return full;

      return 'Learner';
    } catch (_) {
      return 'Learner';
    }
  }

  Future<void> _sendBookingNotifications(_Slot slot, {int? sessionNo}) async {
    try {
      final learnerName = await _getMyFullName();
      final nowMs = DateTime.now().millisecondsSinceEpoch;

      final effectiveSessionNo =
          sessionNo ?? _effectiveGroupSessionNo(slot) ?? _targetSessionNo;
      final safeCourseTitle = courseTitle.trim().isEmpty
          ? 'Course'
          : courseTitle.trim();

      final adminTitle = 'New learner booking';
      final adminBody =
          '$learnerName booked Session $effectiveSessionNo for $safeCourseTitle on ${slot.dayKey} at ${slot.time} with ${slot.teacherName}.';

      final adminEventId =
          'booking_admin_${slot.courseId}_${slot.teacherId}_${slot.dayKey}_${slot.time}_${myUid}_${effectiveSessionNo}_$nowMs';
      final adminUids = await PushDispatchService.loadAdminUids();
      await PushDispatchService.dispatchAdminTopic(
        intent: PushIntent.booking,
        title: adminTitle,
        message: adminBody,
        context: const PushDispatchContext(
          screen: 'learner/learner_booking',
          action: 'booking_admin_push',
        ),
        eventParts: [adminEventId],
        fallbackAdminUids: adminUids,
        data: {
          'targetRole': 'admin',
          'courseId': slot.courseId,
          'courseTitle': safeCourseTitle,
          'teacherId': slot.teacherId,
          'teacherName': slot.teacherName,
          'learnerUid': myUid,
          'learnerName': learnerName,
          'dayKey': slot.dayKey,
          'time': slot.time,
          'sessionNo': effectiveSessionNo.toString(),
        },
      );

      final teacherTitle = 'New class booking';
      final teacherBody =
          '$learnerName booked Session $effectiveSessionNo for $safeCourseTitle on ${slot.dayKey} at ${slot.time}.';

      final teacherEventId =
          'booking_teacher_${slot.courseId}_${slot.teacherId}_${slot.dayKey}_${slot.time}_${myUid}_${effectiveSessionNo}_$nowMs';

      await PushDispatchService.dispatchToUser(
        intent: PushIntent.booking,
        targetUid: slot.teacherId,
        title: teacherTitle,
        message: teacherBody,
        context: const PushDispatchContext(
          screen: 'learner/learner_booking',
          action: 'booking_teacher_push',
        ),
        eventParts: [teacherEventId],
        data: {
          'targetRole': 'teacher',
          'courseId': slot.courseId,
          'courseTitle': safeCourseTitle,
          'teacherId': slot.teacherId,
          'teacherName': slot.teacherName,
          'learnerUid': myUid,
          'learnerName': learnerName,
          'dayKey': slot.dayKey,
          'time': slot.time,
          'sessionNo': effectiveSessionNo.toString(),
        },
      );
    } catch (e, st) {
      await PushErrorLogger.logFailure(
        screen: 'learner/learner_booking',
        action: 'booking_push_send_failed',
        error: e,
        stackTrace: st,
        targetUid: myUid,
        extra: {'type': 'booking', 'route': ''},
      );
    }
  }

  Future<void> _sendCancelNotifications(
    _MyBooking booking, {
    required String cid,
  }) async {
    try {
      final learnerName = await _getMyFullName();
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final safeCourseTitle =
          (courseTitleById[cid] ?? courseTitle).trim().isEmpty
          ? 'Course'
          : (courseTitleById[cid] ?? courseTitle).trim();
      final effectiveSessionNo = booking.sessionNo > 0 ? booking.sessionNo : 0;

      final title = 'Learner canceled booking';
      final body =
          '$learnerName canceled ${effectiveSessionNo > 0 ? 'Session $effectiveSessionNo ' : ''}for $safeCourseTitle on ${booking.dayKey} at ${booking.time} with ${booking.teacherName}.';

      final adminEventId =
          'booking_cancel_admin_${cid}_${booking.teacherId}_${booking.dayKey}_${booking.time}_${myUid}_${effectiveSessionNo > 0 ? effectiveSessionNo : 'na'}_$nowMs';
      final teacherEventId =
          'booking_cancel_teacher_${cid}_${booking.teacherId}_${booking.dayKey}_${booking.time}_${myUid}_${effectiveSessionNo > 0 ? effectiveSessionNo : 'na'}_$nowMs';

      final adminUids = await PushDispatchService.loadAdminUids();
      await PushDispatchService.dispatchAdminTopic(
        intent: PushIntent.booking,
        title: title,
        message: body,
        context: const PushDispatchContext(
          screen: 'learner/learner_booking',
          action: 'booking_cancel_admin_push',
        ),
        eventParts: [adminEventId],
        fallbackAdminUids: adminUids,
        data: {
          'targetRole': 'admin',
          'courseId': cid,
          'courseTitle': safeCourseTitle,
          'teacherId': booking.teacherId,
          'teacherName': booking.teacherName,
          'learnerUid': myUid,
          'learnerName': learnerName,
          'dayKey': booking.dayKey,
          'time': booking.time,
          if (effectiveSessionNo > 0)
            'sessionNo': effectiveSessionNo.toString(),
          'changeType': 'cancel',
        },
      );

      await PushDispatchService.dispatchToUser(
        intent: PushIntent.booking,
        targetUid: booking.teacherId,
        title: title,
        message: body,
        context: const PushDispatchContext(
          screen: 'learner/learner_booking',
          action: 'booking_cancel_teacher_push',
        ),
        eventParts: [teacherEventId],
        data: {
          'targetRole': 'teacher',
          'courseId': cid,
          'courseTitle': safeCourseTitle,
          'teacherId': booking.teacherId,
          'teacherName': booking.teacherName,
          'learnerUid': myUid,
          'learnerName': learnerName,
          'dayKey': booking.dayKey,
          'time': booking.time,
          if (effectiveSessionNo > 0)
            'sessionNo': effectiveSessionNo.toString(),
          'changeType': 'cancel',
        },
      );
    } catch (e, st) {
      await PushErrorLogger.logFailure(
        screen: 'learner/learner_booking',
        action: 'booking_cancel_push_send_failed',
        error: e,
        stackTrace: st,
        targetUid: myUid,
        extra: {'type': 'booking', 'route': ''},
      );
    }
  }

  Future<void> _scheduleLearnerLocalReminder(_Slot slot) async {
    try {
      final settings = await LearnerNotificationSettingsService.load(_authUid);
      if (!settings.masterEnabled || !settings.classEnabled) return;

      await NotificationService.I.init();
      await NotificationService.I.requestPermissions();

      final sessionNo = _effectiveGroupSessionNo(slot) ?? _targetSessionNo;
      final safeCourseTitle = courseTitle.trim().isEmpty
          ? 'Course'
          : courseTitle.trim();

      await NotificationService.I.scheduleSessionReminderSeries(
        classId: '${slot.courseId}_${slot.dayKey}_${slot.time}',
        title: 'Upcoming class',
        body:
            'Session $sessionNo for $safeCourseTitle with ${slot.teacherName}',
        sessionStart: slot.start,
        minutesBeforeList: [settings.classLeadMinutes],
      );
    } catch (_) {}
  }

  List<int> _allClassReminderLeadMinutes() {
    return <int>{
      60,
      20,
      5,
      ...LearnerNotificationSettingsService.leadOptions,
    }.toList();
  }

  Future<void> _runBusy(String label, Future<void> Function() action) async {
    _markBusyVisualStart();
    if (!mounted) return;
    setState(() {
      progressLabel = label;
    });

    try {
      await action();
    } finally {
      if (mounted) {
        setState(() {
          progressLabel = '';
        });
        _clearBusyVisualIfIdle();
      }
    }
  }

  void _setProgressLabel(String label) {
    if (!mounted) return;
    if (label.isNotEmpty) {
      _markBusyVisualStart();
    }
    setState(() {
      progressLabel = label;
    });
    if (label.isEmpty) {
      _clearBusyVisualIfIdle();
    }
  }

  void _markBusyVisualStart() {
    _busyVisualSince ??= DateTime.now();
  }

  void _clearBusyVisualIfIdle() {
    final stillBusy =
        loading || booking || refreshing || progressLabel.isNotEmpty;
    if (!stillBusy) {
      _busyVisualSince = null;
    }
  }

  // ================== Init ==================

  Future<void> _init() async {
    final authUid = FirebaseAuth.instance.currentUser?.uid;
    if (authUid == null) {
      setState(() => loading = false);
      _toast('Not logged in.');
      return;
    }
    _authUid = authUid;
    myUid = await _resolveLearnerUidFromAuth(authUid);

    if (widget.courseId != null && widget.courseId!.trim().isNotEmpty) {
      courseId = widget.courseId!.trim();
    } else {
      final courses = await _loadLearnerBookingCourses();
      if (courses.isEmpty) {
        courseId = null;
      } else if (courses.length == 1) {
        courseId = courses.first.id;
      } else {
        courseId = await _showCourseChooser(courses);
      }
    }
    if (courseId == null || courseId!.isEmpty) {
      setState(() => loading = false);
      _toast('No courseId found for this learner.');
      return;
    }

    final gate = await _bookingGateForCourse(courseId!);
    if (!gate.enabled) {
      setState(() => loading = false);
      _toast('Booking is not enabled for this course yet.');
      return;
    }

    if (gate.title.isNotEmpty) courseTitle = gate.title;
    if (gate.totalSessions > 0) totalSessions = gate.totalSessions;

    await _loadCurriculum(courseId!);
    await _loadOrCreateProgress(courseId!);
    await _loadStudiedSessions(courseId!);

    await _inferClassIdForCourse(courseId!);

    await _loadReservationsSummary(courseId!);
    await _generateSlots(courseId!);
    await _recomputeRecommendedSessionNo(courseId!);

    if (!mounted) return;
    setState(() => loading = false);
  }

  Future<List<_CourseChoice>> _loadLearnerBookingCourses() async {
    final out = <_CourseChoice>[];
    try {
      final snap = await _db.child('users/$_authUid/courses').get();
      final v = snap.value;
      if (v is! Map) return out;

      final courses = v.map((k, vv) => MapEntry(k.toString(), vv));

      final catalogSnap = await _db.child('courses').get();
      final coursesCatalog = (catalogSnap.value is Map)
          ? (catalogSnap.value as Map).map(
              (k, vv) => MapEntry(k.toString(), vv),
            )
          : <String, dynamic>{};

      for (final entry in courses.entries) {
        final raw = entry.value;
        if (raw is! Map) continue;

        final m = raw.map((k, vv) => MapEntry(k.toString(), vv));

        final id = (m['id'] ?? m['courseId'] ?? m['course_id'] ?? '')
            .toString()
            .trim();

        final variantKey = (m['variantKey'] ?? m['variant'] ?? '')
            .toString()
            .trim()
            .toLowerCase();

        final deliveryKey = (m['deliveryKey'] ?? '')
            .toString()
            .trim()
            .toLowerCase();

        final isBookingCourse =
            variantKey == 'flexible' || deliveryKey == 'flexible';

        if (id.isNotEmpty && isBookingCourse) {
          final title = (m['title'] ?? m['courseTitle'] ?? m['name'] ?? id)
              .toString()
              .trim();
          final code = (m['course_code'] ?? '').toString();
          final key = entry.key.toString();
          final catalogNode = coursesCatalog[id] ?? coursesCatalog[key];
          final catalogMap = (catalogNode is Map)
              ? catalogNode.map((k, vv) => MapEntry(k.toString(), vv))
              : <String, dynamic>{};
          final thumb = (catalogMap['thumbnail'] ?? '').toString().trim();
          out.add(
            _CourseChoice(
              id: id,
              title: title.isEmpty ? id : title,
              courseCode: code,
              thumbnailUrl: thumb,
            ),
          );
        }
      }
    } catch (_) {}

    final seen = <String>{};
    final unique = <_CourseChoice>[];
    for (final c in out) {
      if (seen.add(c.id)) unique.add(c);
    }
    return unique;
  }

  Future<String?> _showCourseChooser(List<_CourseChoice> courses) async {
    if (!mounted) return null;
    final p = palette;
    final isAr = lessonChoiceArabic;
    final pageController = PageController(viewportFraction: 0.94);
    var currentPage = 0;

    try {
      return showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (dialogCtx) {
          return Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 22,
            ),
            child: StatefulBuilder(
              builder: (context, setDialogState) {
                return ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: 760,
                    maxHeight: MediaQuery.of(context).size.height * 0.76,
                  ),
                  child: Container(
                    decoration: BoxDecoration(
                      color: p.appBg,
                      borderRadius: BorderRadius.circular(28),
                      border: Border.all(
                        color: p.border.withValues(alpha: 0.9),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.12),
                          blurRadius: 26,
                          offset: const Offset(0, 14),
                        ),
                      ],
                    ),
                    child: SafeArea(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(14, 14, 14, 16),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              isAr ? 'اختر دورة' : 'Choose course',
                              style: TextStyle(
                                fontWeight: FontWeight.w900,
                                fontSize: 18,
                                color: p.primary,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              isAr
                                  ? 'اسحب لليسار أو اليمين لعرض جميع الدورات'
                                  : 'Swipe left or right to view all courses',
                              style: TextStyle(
                                color: p.text.withValues(alpha: 0.64),
                                fontWeight: FontWeight.w700,
                                fontSize: 12,
                              ),
                            ),
                            const SizedBox(height: 14),
                            SizedBox(
                              height: 276,
                              child: PageView.builder(
                                controller: pageController,
                                itemCount: courses.length,
                                onPageChanged: (index) {
                                  setDialogState(() => currentPage = index);
                                },
                                itemBuilder: (_, i) {
                                  final c = courses[i];
                                  return Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                    ),
                                    child: InkWell(
                                      borderRadius: BorderRadius.circular(20),
                                      onTap: () =>
                                          Navigator.pop(dialogCtx, c.id),
                                      child: Container(
                                        padding: const EdgeInsets.all(12),
                                        decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(
                                            20,
                                          ),
                                          gradient: LinearGradient(
                                            begin: Alignment.topLeft,
                                            end: Alignment.bottomRight,
                                            colors: [
                                              p.cardBg,
                                              p.soft.withValues(alpha: 0.9),
                                            ],
                                          ),
                                          border: Border.all(
                                            color: p.border.withValues(
                                              alpha: 0.8,
                                            ),
                                          ),
                                          boxShadow: [
                                            BoxShadow(
                                              color: Colors.black.withValues(
                                                alpha: 0.06,
                                              ),
                                              blurRadius: 14,
                                              offset: const Offset(0, 8),
                                            ),
                                          ],
                                        ),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Stack(
                                              children: [
                                                Container(
                                                  width: double.infinity,
                                                  height: 138,
                                                  decoration: BoxDecoration(
                                                    color: p.appBg,
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          16,
                                                        ),
                                                    border: Border.all(
                                                      color: p.border
                                                          .withValues(
                                                            alpha: 0.9,
                                                          ),
                                                    ),
                                                  ),
                                                  clipBehavior: Clip.antiAlias,
                                                  child:
                                                      c.thumbnailUrl.isNotEmpty
                                                      ? Image.network(
                                                          c.thumbnailUrl,
                                                          fit: BoxFit.cover,
                                                          filterQuality:
                                                              FilterQuality.low,
                                                          errorBuilder:
                                                              (
                                                                context,
                                                                error,
                                                                stackTrace,
                                                              ) => Center(
                                                                child: Icon(
                                                                  Icons
                                                                      .menu_book_rounded,
                                                                  color:
                                                                      p.primary,
                                                                  size: 34,
                                                                ),
                                                              ),
                                                        )
                                                      : Center(
                                                          child: Icon(
                                                            Icons
                                                                .menu_book_rounded,
                                                            color: p.primary,
                                                            size: 34,
                                                          ),
                                                        ),
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 6),
                                            Text(
                                              c.title,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontWeight: FontWeight.w900,
                                                color: p.primary,
                                                fontSize: 16,
                                              ),
                                            ),
                                            const SizedBox(height: 6),
                                            Row(
                                              children: [
                                                Expanded(
                                                  child: Text(
                                                    c.courseCode.isEmpty
                                                        ? 'Code: —'
                                                        : 'Code: ${c.courseCode}',
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: TextStyle(
                                                      color: p.text.withValues(
                                                        alpha: 0.72,
                                                      ),
                                                      fontSize: 11,
                                                      fontWeight:
                                                          FontWeight.w800,
                                                    ),
                                                  ),
                                                ),
                                                const SizedBox(width: 8),
                                                FilledButton(
                                                  style: FilledButton.styleFrom(
                                                    backgroundColor: p.primary,
                                                    foregroundColor:
                                                        Colors.white,
                                                    visualDensity:
                                                        VisualDensity.compact,
                                                    padding:
                                                        const EdgeInsets.symmetric(
                                                          horizontal: 12,
                                                          vertical: 8,
                                                        ),
                                                    shape: RoundedRectangleBorder(
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            10,
                                                          ),
                                                    ),
                                                  ),
                                                  onPressed: () =>
                                                      Navigator.pop(
                                                        dialogCtx,
                                                        c.id,
                                                      ),
                                                  child: Text(
                                                    isAr
                                                        ? 'احجز هذه الدورة'
                                                        : 'Book this course',
                                                    style: const TextStyle(
                                                      fontSize: 11,
                                                      fontWeight:
                                                          FontWeight.w900,
                                                    ),
                                                  ),
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
                            const SizedBox(height: 10),
                            Center(
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: List.generate(courses.length, (
                                  index,
                                ) {
                                  final selected = currentPage == index;
                                  return AnimatedContainer(
                                    duration: const Duration(milliseconds: 220),
                                    margin: const EdgeInsets.symmetric(
                                      horizontal: 3,
                                    ),
                                    width: selected ? 18 : 7,
                                    height: 7,
                                    decoration: BoxDecoration(
                                      color: selected
                                          ? p.primary
                                          : p.border.withValues(alpha: 0.75),
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                  );
                                }),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          );
        },
      );
    } finally {
      pageController.dispose();
    }
  }

  Future<String> _inferClassIdForCourse(String cid) async {
    try {
      final snap = await _db.child('classes').get();
      if (!snap.exists || snap.value is! Map) return '';

      final all = Map<dynamic, dynamic>.from(snap.value as Map);

      for (final entry in all.entries) {
        final classId = entry.key.toString();
        final val = entry.value;
        if (val is! Map) continue;

        final c = val.map((k, v) => MapEntry(k.toString(), v));
        final courseIdAny =
            (c['course_id'] ?? c['courseId'] ?? c['course'] ?? '')
                .toString()
                .trim();
        if (courseIdAny != cid) continue;

        final learners = c['learners'];
        if (learners is Map) {
          final lm = Map<dynamic, dynamic>.from(learners);
          if (lm.containsKey(myUid)) return classId;
        }
      }
    } catch (_) {}
    return '';
  }

  // ================== Booking Gate ==================

  Future<_BookingGate> _bookingGateForCourse(String cid) async {
    try {
      final snap = await _db.child('syllabi/$cid/flexible').get();

      if (snap.exists && snap.value is Map) {
        final m = (snap.value as Map).map((k, v) => MapEntry(k.toString(), v));

        final String title = (m['title'] ?? '').toString().trim();
        int total = 0;

        final units = m['units'];
        if (units is List) {
          for (final u in units) {
            if (u is! Map) continue;
            final unit = u.map((k, v) => MapEntry(k.toString(), v));
            final sessions = unit['sessions'];

            if (sessions is List) {
              total += sessions.length;
            }
          }
        }

        return _BookingGate(
          enabled: true,
          totalSessions: total,
          title: title,
          source: 'syllabi/flexible',
        );
      }
    } catch (_) {}

    return const _BookingGate(
      enabled: false,
      totalSessions: 0,
      title: '',
      source: 'none',
    );
  }

  // ================== Load Curriculum ==================

  Future<void> _loadCurriculum(String cid) async {
    try {
      final snap = await _db.child('syllabi/$cid/flexible').get();
      if (!snap.exists || snap.value == null || snap.value is! Map) return;

      final root = (snap.value as Map).map(
        (k, vv) => MapEntry(k.toString(), vv),
      );

      final t = (root['title'] ?? '').toString().trim();
      if (t.isNotEmpty) courseTitle = t;

      final units = root['units'];
      final Map<String, dynamic> out = {};
      final List<Map<String, dynamic>> outUnits = [];
      int fallbackNo = 1;

      if (units is List) {
        for (final u in units) {
          if (u is! Map) continue;
          final unit = u.map((k, vv) => MapEntry(k.toString(), vv));
          final rawSessions = unit['sessions'];

          if (rawSessions is! List) continue;

          final List<Map<String, dynamic>> unitSessions = [];
          for (final s in rawSessions) {
            if (s is! Map) continue;
            final sess = s.map((k, vv) => MapEntry(k.toString(), vv));

            final sourceSessionNo = _toInt(sess['sessionNumber'], fallback: 0);
            final no = fallbackNo;

            final entry = <String, dynamic>{
              'sessionNo': no,
              'sourceSessionNumber': sourceSessionNo,
              'sessionTitle': (sess['title'] ?? '').toString(),
              'objective': (sess['objective'] ?? '').toString(),
              'content': (sess['content'] ?? '').toString(),
              'homework': (sess['homework'] ?? '').toString(),
              'durationMinutes': _toInt(sess['durationMinutes'], fallback: 0),
              'source': 'syllabi/flexible',
            };

            out['$no'] = entry;
            unitSessions.add(entry);
            fallbackNo++;
          }

          outUnits.add({
            'unitId': (unit['id'] ?? '').toString(),
            'unitTitle': (unit['title'] ?? 'Unit').toString(),
            'unitDescription': (unit['description'] ?? '').toString().trim(),
            'unitOrder': unit['order'] ?? 0,
            'sessions': unitSessions,
          });
        }
      }

      curriculumSessions = out;
      curriculumUnits = outUnits;

      if (totalSessions <= 0) {
        totalSessions = out.length;
      }
    } catch (e) {
      _toast('Failed to load booking syllabus: $e');
    }
  }

  // ================== Load / Create Progress ==================

  Future<void> _loadOrCreateProgress(String cid) async {
    try {
      final ref = _progressRef(cid);
      final snap = await ref.get();
      final raw = snap.value;

      final sessionNo = _readSessionNoFromProgress(raw);
      currentSession = sessionNo > 0 ? sessionNo : 1;
      selectedSessionNo = currentSession;

      final needsCanonicalWrite =
          raw == null ||
          raw is! Map ||
          _asStringKeyMap(raw)['currentSession'] == null;

      if (needsCanonicalWrite) {
        await ref.set({
          'currentSession': currentSession,
          'updatedAt': ServerValue.timestamp,
        });
      }
    } catch (e) {
      currentSession = 1;
      selectedSessionNo = 1;
      try {
        await _progressRef(
          cid,
        ).set({'currentSession': 1, 'updatedAt': ServerValue.timestamp});
      } catch (writeError) {
        final lower = writeError.toString().toLowerCase();
        final denied =
            lower.contains('permission-denied') ||
            lower.contains('permission denied');
        if (!denied) {
          _toast(
            toHumanError(
              writeError,
              fallback: 'Could not load your booking progress.',
            ),
          );
        }
      }
    }
  }

  Future<void> _loadStudiedSessions(String cid) async {
    try {
      final snap = await _progressRef(cid).child('online_attendance').get();
      studiedSessionsConsumed = countPresentOnlineAttendance(snap.value);
    } catch (_) {
      studiedSessionsConsumed = 0;
    }
  }

  // ================== Load Reservations Summary ==================

  Future<void> _loadReservationsSummary(String cid) async {
    final now = DateTime.now();
    final Map<String, int> mine = {};
    final Map<String, _SlotSummary> summary = {};
    final Map<String, _GlobalSlotOccupancy> global = {};
    final Map<String, String> courseTitles = {};

    try {
      final coursesSnap = await _db.child('courses').get();
      if (coursesSnap.value is Map) {
        final coursesMap = (coursesSnap.value as Map).map(
          (k, vv) => MapEntry(k.toString(), vv),
        );
        for (final entry in coursesMap.entries) {
          final raw = entry.value;
          if (raw is! Map) continue;
          final m = raw.map((k, vv) => MapEntry(k.toString(), vv));
          final title = (m['title'] ?? m['name'] ?? entry.key)
              .toString()
              .trim();
          courseTitles[entry.key] = title.isEmpty ? entry.key : title;
        }
      }

      final allReservationsSnap = await _db.child('booking_reservations').get();
      if (allReservationsSnap.value is Map) {
        final allCourses = (allReservationsSnap.value as Map).map(
          (k, vv) => MapEntry(k.toString(), vv),
        );

        for (final courseEntry in allCourses.entries) {
          final globalCourseId = courseEntry.key.toString();
          final courseNode = courseEntry.value;
          if (courseNode is! Map) continue;
          final daysNode = courseNode.map(
            (k, vv) => MapEntry(k.toString(), vv),
          );

          for (final dayEntry in daysNode.entries) {
            final dk = dayEntry.key.toString();
            final dayNode = dayEntry.value;
            if (dayNode is! Map) continue;
            final timesNode = dayNode.map(
              (k, vv) => MapEntry(k.toString(), vv),
            );

            for (final timeEntry in timesNode.entries) {
              final hhmm = timeEntry.key.toString();
              final timeNode = timeEntry.value;
              if (timeNode is! Map) continue;
              final teachersAtTime = timeNode.map(
                (k, vv) => MapEntry(k.toString(), vv),
              );

              for (final teacherEntry in teachersAtTime.entries) {
                final teacherId = teacherEntry.key.toString().trim();
                final slotNode = teacherEntry.value;
                if (teacherId.isEmpty || slotNode is! Map) continue;

                final sm = slotNode.map((k, vv) => MapEntry(k.toString(), vv));
                final learnersRaw = sm['learners'];
                if (learnersRaw is! Map) continue;
                final learners = learnersRaw.map(
                  (k, vv) => MapEntry(k.toString(), vv),
                );
                final count = learners.length;
                if (count <= 0) continue;

                final rawSessionNo = _toInt(sm['sessionNo'], fallback: 0);
                final groupSessionNo = rawSessionNo > 0 ? rawSessionNo : null;
                final key = _slotSummaryKey(dk, hhmm, teacherId);
                global[key] = _GlobalSlotOccupancy(
                  courseId: globalCourseId,
                  sessionNo: groupSessionNo,
                  learnerCount: count,
                  bookedByMe: learners.containsKey(myUid),
                );
              }
            }
          }
        }
      }

      final dayKeys = <String>[];
      for (int i = 0; i < daysAhead; i++) {
        final day = DateTime(
          now.year,
          now.month,
          now.day,
        ).add(Duration(days: i));
        dayKeys.add(_dateKey(day));
      }

      final snaps = await Future.wait(
        dayKeys.map((dk) => _reservationsRootRef(cid).child(dk).get()),
      );

      for (int i = 0; i < dayKeys.length; i++) {
        final dk = dayKeys[i];
        final snap = snaps[i];
        if (!snap.exists || snap.value == null || snap.value is! Map) continue;

        final m = (snap.value as Map).map(
          (k, vv) => MapEntry(k.toString(), vv),
        );

        for (final e in m.entries) {
          final hhmm = e.key.toString();
          final timeNode = e.value;
          if (timeNode is! Map) continue;

          final teachersAtTime = timeNode.map(
            (k, vv) => MapEntry(k.toString(), vv),
          );

          for (final teacherEntry in teachersAtTime.entries) {
            final teacherId = teacherEntry.key.toString();
            final slotNode = teacherEntry.value;
            if (slotNode is! Map) continue;

            final sm = slotNode.map((k, vv) => MapEntry(k.toString(), vv));

            final learnersRaw = sm['learners'];
            if (learnersRaw is! Map) continue;

            final learners = learnersRaw.map(
              (k, vv) => MapEntry(k.toString(), vv),
            );
            final count = learners.length;
            if (count <= 0) continue;

            final groupSessionNo = _toInt(sm['sessionNo'], fallback: 0);
            final groupSession = groupSessionNo <= 0 ? null : groupSessionNo;

            final key = _slotSummaryKey(dk, hhmm, teacherId);

            summary[key] = _SlotSummary(
              bookedCount: count,
              groupSessionNo: groupSession,
              bookedByMe: learners.containsKey(myUid),
            );

            if (learners.containsKey(myUid)) {
              mine[key] = groupSession ?? currentSession;
            }
          }
        }
      }
    } catch (_) {}

    if (!mounted) return;
    setState(() {
      myBookedSlots = mine;
      slotSummary = summary;
      globalSlotOccupancy = global;
      courseTitleById = courseTitles;
      upcomingBookingsCount = mine.length;
    });
  }

  Future<List<_MyBooking>> _findMyUpcomingBookings(String cid) async {
    final now = DateTime.now();
    final byKey = <String, _MyBooking>{};

    try {
      final dayKeys = <String>[];
      for (int i = 0; i < daysAhead; i++) {
        final day = DateTime(
          now.year,
          now.month,
          now.day,
        ).add(Duration(days: i));
        dayKeys.add(_dateKey(day));
      }

      final snaps = await Future.wait(
        dayKeys.map((dk) => _reservationsRootRef(cid).child(dk).get()),
      );

      for (int i = 0; i < dayKeys.length; i++) {
        final dk = dayKeys[i];
        final snap = snaps[i];
        if (!snap.exists || snap.value == null || snap.value is! Map) continue;

        final m = (snap.value as Map).map(
          (k, vv) => MapEntry(k.toString(), vv),
        );

        for (final e in m.entries) {
          final hhmm = e.key.toString();
          final timeNode = e.value;
          if (timeNode is! Map) continue;

          final start = _parseSlotStart(dk, hhmm);
          if (start == null) continue;
          if (!start.isAfter(now)) continue;

          void considerNode(Map<dynamic, dynamic> nodeLike, String teacherKey) {
            final sm = nodeLike.map((k, vv) => MapEntry(k.toString(), vv));
            final learners = sm['learners'];
            if (learners is! Map) return;

            final lm = learners.map((k, vv) => MapEntry(k.toString(), vv));
            if (!lm.containsKey(myUid)) return;

            final tIdRaw = (sm['teacherId'] ?? teacherKey).toString().trim();
            final tId = tIdRaw.isEmpty ? '__legacy__' : tIdRaw;
            final tName = (sm['teacherName'] ?? 'Teacher').toString().trim();
            final sNo = _toInt(sm['sessionNo'], fallback: 0);

            final candidate = _MyBooking(
              dayKey: dk,
              time: hhmm,
              start: start,
              teacherId: tId,
              teacherName: tName,
              sessionNo: sNo,
            );

            byKey['$dk|$hhmm|$tId'] = candidate;
          }

          final teachersAtTime = timeNode.map((k, vv) => MapEntry(k, vv));
          if (teachersAtTime['learners'] is Map) {
            considerNode(teachersAtTime, '');
            continue;
          }

          for (final teacherEntry in teachersAtTime.entries) {
            final teacherId = teacherEntry.key.toString();
            final node = teacherEntry.value;
            if (node is! Map) continue;
            considerNode(node, teacherId);
          }
        }
      }
    } catch (_) {}

    final out = byKey.values.toList();
    out.sort((a, b) {
      final byStart = a.start.compareTo(b.start);
      if (byStart != 0) return byStart;
      final byDay = a.dayKey.compareTo(b.dayKey);
      if (byDay != 0) return byDay;
      final byTime = a.time.compareTo(b.time);
      if (byTime != 0) return byTime;
      return a.teacherId.compareTo(b.teacherId);
    });
    return out;
  }

  Future<_GlobalSlotOccupancy?> _loadLiveGlobalOccupancyForSlot(
    _Slot slot,
  ) async {
    try {
      final snap = await _db.child('booking_reservations').get();
      if (snap.value is! Map) return null;

      final root = (snap.value as Map).map(
        (k, vv) => MapEntry(k.toString(), vv),
      );
      for (final courseEntry in root.entries) {
        final occupiedCourseId = courseEntry.key.toString();
        final courseNode = courseEntry.value;
        if (courseNode is! Map) continue;
        final dayNode = courseNode[slot.dayKey];
        if (dayNode is! Map) continue;
        final timeNode = dayNode[slot.time];
        if (timeNode is! Map) continue;
        final teacherNode = timeNode[slot.teacherId];
        if (teacherNode is! Map) continue;

        final sm = teacherNode.map((k, vv) => MapEntry(k.toString(), vv));
        final learnersRaw = sm['learners'];
        if (learnersRaw is! Map) continue;
        final learners = learnersRaw.map((k, vv) => MapEntry(k.toString(), vv));
        final count = learners.length;
        if (count <= 0) continue;
        final rawSessionNo = _toInt(sm['sessionNo'], fallback: 0);

        return _GlobalSlotOccupancy(
          courseId: occupiedCourseId,
          sessionNo: rawSessionNo > 0 ? rawSessionNo : null,
          learnerCount: count,
          bookedByMe: learners.containsKey(myUid),
        );
      }
    } catch (_) {}

    return null;
  }

  // ================== Availability -> Upcoming Slots ==================

  Future<void> _generateSlots(String cid) async {
    setState(() => generatedSlots = []);
    final now = DateTime.now();

    try {
      final snap = await _availabilityRootRef().get();
      if (!snap.exists || snap.value == null || snap.value is! Map) {
        return;
      }

      final root = (snap.value as Map).map(
        (k, vv) => MapEntry(k.toString(), vv),
      );
      final teacherIds = root.keys.toList();
      final teacherMeetUrls = <String, String>{};
      final teacherMini = <String, _TeacherMiniProfile>{};
      if (teacherIds.isNotEmpty) {
        final urls = await Future.wait(
          teacherIds.map(_loadTeacherProfileMeetUrl),
        );
        final minis = await Future.wait(
          teacherIds.map(_loadTeacherMiniProfile),
        );
        for (int i = 0; i < teacherIds.length; i++) {
          teacherMeetUrls[teacherIds[i]] = urls[i];
          teacherMini[teacherIds[i]] = minis[i];
        }
      }
      final busyByTeacherDay = await _loadTeacherBusyRangesForWindow();
      final List<_TeacherAvail> teachers = [];

      for (final entry in root.entries) {
        final teacherId = entry.key.toString();
        final teacherNode = entry.value;
        if (teacherNode is! Map) continue;

        final tn = teacherNode.map((k, vv) => MapEntry(k.toString(), vv));

        bool teacherOnlineEnabled = true;
        final settingsNode = tn['settings'];
        if (settingsNode is Map) {
          final sm = settingsNode.map((k, vv) => MapEntry(k.toString(), vv));
          teacherOnlineEnabled = _toBool(
            sm['teacherOnlineEnabled'],
            fallback: true,
          );
        }
        if (!teacherOnlineEnabled) continue;

        final perCourse = tn[cid];
        if (perCourse is! Map) continue;

        final effective = perCourse.map((k, vv) => MapEntry(k.toString(), vv));

        final courseOnlineEnabled = _toBool(
          effective['courseOnlineEnabled'],
          fallback: true,
        );
        if (!courseOnlineEnabled) continue;

        final resolvedTeacherName =
            (effective['teacherName'] ??
                    effective['teacher_name'] ??
                    tn['teacherName'] ??
                    tn['teacher_name'] ??
                    '')
                .toString()
                .trim();

        final meetUrl = teacherMeetUrls[teacherId] ?? '';
        final mini =
            teacherMini[teacherId] ??
            const _TeacherMiniProfile(
              name: 'Teacher',
              photoUrl: '',
              hasIntroVideo: false,
            );

        int durationMin = _toInt(effective['durationMinutes'], fallback: 0);
        if (durationMin <= 0) {
          durationMin = _toInt(effective['durationMin'], fallback: 0);
        }
        if (durationMin <= 0) durationMin = 60;

        int maxLearners = _toInt(effective['maxLearnersPerSlot'], fallback: 0);
        if (maxLearners <= 0) maxLearners = 6;

        final week = effective['week'];
        if (week is! Map) continue;

        final wm = week.map((k, vv) => MapEntry(k.toString(), vv));

        final Map<String, List<String>> slotsByDay = {};
        for (final dk in ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun']) {
          final list = wm[dk];
          final out = <String>[];
          if (list is List) {
            for (final item in list) {
              final s = item.toString().trim();
              if (s.contains(':')) out.add(s);
            }
          }
          slotsByDay[dk] = out;
        }

        teachers.add(
          _TeacherAvail(
            teacherId: teacherId,
            teacherName: resolvedTeacherName.isEmpty
                ? mini.name
                : resolvedTeacherName,
            slotsByDay: slotsByDay,
            meetUrl: meetUrl,
            teacherPhotoUrl: mini.photoUrl,
            hasIntroVideo: mini.hasIntroVideo,
            durationMinutes: durationMin,
            maxLearnersPerSlot: maxLearners,
          ),
        );
      }

      if (teachers.isEmpty) return;

      final List<_Slot> out = [];
      for (int i = 0; i < daysAhead; i++) {
        final day = DateTime(
          now.year,
          now.month,
          now.day,
        ).add(Duration(days: i));
        final wk = _weekdayKey(day);
        final dayKey = _dateKey(day);

        for (final t in teachers) {
          final list = t.slotsByDay[wk] ?? const [];
          for (final hhmm in list) {
            final start = _parseSlotStart(dayKey, hhmm);
            if (start == null) continue;
            if (start.isBefore(now.add(const Duration(minutes: 1)))) continue;
            if (_hasClassConflict(
              busyByTeacherDay,
              t.teacherId,
              start,
              t.durationMinutes,
            )) {
              continue;
            }

            final slotKey = _slotSummaryKey(dayKey, hhmm, t.teacherId);
            final summ = slotSummary[slotKey];

            final bookedCount = summ?.bookedCount ?? 0;
            final groupSessionNo = summ?.groupSessionNo;
            final bookedByMe = summ?.bookedByMe == true;

            out.add(
              _Slot(
                courseId: cid,
                dayKey: dayKey,
                time: hhmm,
                start: start,
                teacherId: t.teacherId,
                teacherName: t.teacherName,
                meetUrl: t.meetUrl,
                teacherPhotoUrl: t.teacherPhotoUrl,
                hasIntroVideo: t.hasIntroVideo,
                durationMinutes: t.durationMinutes,
                maxLearnersPerSlot: t.maxLearnersPerSlot,
                bookedByMe: bookedByMe,
                bookedCount: bookedCount,
                groupSessionNo: groupSessionNo,
              ),
            );
          }
        }
      }

      out.sort((a, b) => a.start.compareTo(b.start));
      if (!mounted) return;

      setState(() {
        generatedSlots = out;
      });
      _prefetchTeacherFullProfiles(out);
    } catch (e) {
      _toast('Failed to generate slots: $e');
      if (!mounted) return;
      setState(() => generatedSlots = []);
    }
  }

  // ================== Booking ==================

  Future<void> _bookSlot(_Slot slot, {required int sessionNo}) async {
    if (booking || refreshing) return;
    final cid = courseId;
    if (cid == null) return;
    void stopChecking() {
      if (!mounted) return;
      setState(() => progressLabel = '');
      _clearBusyVisualIfIdle();
    }

    _bookingCancelled = false;
    _setProgressLabel('Checking slot...');

    _GlobalSlotOccupancy? liveOccupancyFor24h;
    if (_isWithin24Hours(slot)) {
      liveOccupancyFor24h = await _loadLiveGlobalOccupancyForSlot(slot);
      if (_bookingCancelled) {
        stopChecking();
        return;
      }
      final sameLevelJoinWithin24h =
          liveOccupancyFor24h != null &&
          liveOccupancyFor24h.courseId == cid &&
          liveOccupancyFor24h.learnerCount > 0 &&
          liveOccupancyFor24h.learnerCount <
              (slot.maxLearnersPerSlot <= 0 ? 6 : slot.maxLearnersPerSlot);
      if (!sameLevelJoinWithin24h) {
        _toast('Booking closes 24 hours before class.');
        stopChecking();
        return;
      }
    }

    final latestBusyByTeacherDay = await _loadTeacherBusyRangesForWindow();
    if (_bookingCancelled) {
      stopChecking();
      return;
    }
    if (_hasClassConflict(
      latestBusyByTeacherDay,
      slot.teacherId,
      slot.start,
      slot.durationMinutes,
    )) {
      _toast(
        'This teacher has an in-class session at this time. Please pick another slot.',
      );
      await _generateSlots(cid);
      stopChecking();
      return;
    }

    var targetSession = sessionNo;

    final shouldWarn = await _hasPossibleMissingAttendanceForSession(
      cid: cid,
      sessionNo: targetSession,
    );
    if (!mounted) return;
    if (_bookingCancelled) {
      stopChecking();
      return;
    }

    if (shouldWarn) {
      final decision = await _askSessionCheckBeforeBooking(targetSession);
      if (!mounted) return;
      if (_bookingCancelled) {
        stopChecking();
        return;
      }

      if (decision == null) {
        stopChecking();
        return;
      }

      if (decision == false) {
        final maxSessions = _effectiveTotalSessions;
        final suggested = (targetSession + 1).clamp(1, maxSessions).toInt();

        setState(() {
          studyMode = 'custom';
          lessonsExpanded = true;
          selectedSessionNo = suggested;
        });

        _toast('Choose the session you want, then tap Book again.');
        stopChecking();
        return;
      }
    }

    if (_effectiveTotalSessions <= 0) {
      _toast('Booking enabled, but total lessons not set.');
      stopChecking();
      return;
    }

    if (targetSession > _effectiveTotalSessions) {
      _toast('You already finished this course.');
      stopChecking();
      return;
    }

    if (!_isJoinable(slot)) {
      if (_isBookingLockedForNewBooking(slot)) {
        _toast('Booking closes 24 hours before class.');
        stopChecking();
        return;
      }
      final blockedSession = _effectiveGroupSessionNo(slot);
      if (blockedSession != null && blockedSession != targetSession) {
        _toast(
          'This class time is for Session $blockedSession. Please choose a time for Session $targetSession.',
        );
        stopChecking();
        return;
      }
      if (_isSlotFull(slot)) {
        _toast('This slot is full.');
        stopChecking();
        return;
      }
      _toast('You can’t join this slot.');
      stopChecking();
      return;
    }

    setState(() => booking = true);
    _markBusyVisualStart();

    try {
      if (_bookingCancelled) return;
      final liveOccupancy =
          liveOccupancyFor24h ?? await _loadLiveGlobalOccupancyForSlot(slot);
      if (_bookingCancelled) return;
      if (liveOccupancy != null &&
          liveOccupancy.courseId != cid &&
          !liveOccupancy.bookedByMe) {
        _toast(
          'This teacher is already booked at this time for another level.',
        );
        return;
      }

      if (liveOccupancy != null &&
          liveOccupancy.courseId == cid &&
          liveOccupancy.sessionNo != null &&
          liveOccupancy.sessionNo != targetSession &&
          !liveOccupancy.bookedByMe) {
        final groupSession = liveOccupancy.sessionNo!;
        final levelLabel = _levelLabelForCourseId(liveOccupancy.courseId);
        _setProgressLabel('Preparing confirmation...');
        final ok = await _confirmJoinWithSessionChange(
          selectedSession: targetSession,
          groupSession: groupSession,
          levelLabel: levelLabel,
        );
        if (!mounted) return;
        if (_bookingCancelled) return;
        if (ok != true) return;
        setState(() {
          studyMode = 'custom';
          selectedSessionNo = groupSession;
          confirmSessionNo = groupSession;
        });
        targetSession = groupSession;
      }

      final upcoming = await _findMyUpcomingBookings(cid);
      _MyBooking? existingSameTime;
      for (final b in upcoming) {
        if (b.dayKey == slot.dayKey && b.time == slot.time) {
          existingSameTime = b;
          break;
        }
      }
      final isCustomMode = studyMode == 'custom';
      final totalUpcoming = upcoming.length;
      final sameTimeDifferentTeacher = upcoming.any(
        (b) =>
            b.dayKey == slot.dayKey &&
            b.time == slot.time &&
            b.teacherId != slot.teacherId,
      );

      final sameExact = upcoming.any(
        (b) =>
            b.dayKey == slot.dayKey &&
            b.time == slot.time &&
            b.teacherId == slot.teacherId,
      );
      if (sameExact) {
        _toast('You already booked this exact class time with this teacher.');
        return;
      }

      _MyBooking? sameSessionUpcoming;
      for (final b in upcoming) {
        if (b.sessionNo == targetSession) {
          sameSessionUpcoming = b;
          break;
        }
      }
      if (sameSessionUpcoming != null) {
        _toast(
          'You already have Session $targetSession booked with ${sameSessionUpcoming.teacherName} on ${sameSessionUpcoming.dayKey} at ${sameSessionUpcoming.time}. Please choose another session.',
        );
        return;
      }

      if (totalUpcoming >= 3) {
        _toast(
          _bilingual(
            'You already booked 3 sessions. Please cancel one first.',
            'لقد حجزت 3 دروس بالفعل. يرجى إلغاء واحدة أولاً.',
          ),
        );
        return;
      }

      if (isCustomMode) {
        if (sameTimeDifferentTeacher) {
          _toast(
            _bilingual(
              'You already booked this date and time with another teacher.',
              'لقد حجزت هذا التاريخ والوقت بالفعل مع معلم آخر.',
            ),
          );
          return;
        }

        final count = totalUpcoming;
        if (count >= 3) {
          _toast(
            _bilingual(
              'You already booked 3 sessions. Please cancel one first.',
              'لقد حجزت 3 دروس بالفعل. يرجى إلغاء واحدة أولاً.',
            ),
          );
          return;
        }

        if (count == 1 || count == 2) {
          _setProgressLabel('Preparing confirmation...');
          final ok = await _confirmWithLogo(
            title: 'Booking limit | حد الحجز',
            message:
                'You already booked $count ${count == 1 ? 'session' : 'sessions'}.\nYou can book up to 3 sessions.\n\nلقد حجزت $count ${count == 1 ? 'درس' : 'دروس'} بالفعل.\nيمكنك حجز حتى 3 دروس.\n\nContinue booking this slot?\nمتابعة حجز هذه الحصة؟',
            confirmLabel: 'Continue',
          );
          if (!mounted) return;
          if (ok != true) return;
        }
      }

      if (existingSameTime != null &&
          existingSameTime.teacherId == slot.teacherId) {
        _toast('You already booked this exact class time with this teacher.');
        return;
      }

      if (!isCustomMode &&
          sameTimeDifferentTeacher &&
          existingSameTime != null) {
        final msg =
            'You already booked this time with another teacher.\nDo you want to change teacher?\n\nCurrent: ${existingSameTime.teacherName} — ${_friendlyDate(existingSameTime.start)} ${existingSameTime.time}\nNew: ${slot.teacherName} — ${_friendlyDate(slot.start)} ${slot.time}\n\nThis will keep the same date and time and only change the teacher.';
        _setProgressLabel('Preparing confirmation...');
        final ok = await _confirmWithLogo(
          title: 'Change teacher',
          message: msg,
          confirmLabel: 'Yes, Change Teacher',
        );
        if (!mounted) return;
        if (ok != true) return;

        final locked = !existingSameTime.start.isAfter(
          DateTime.now().add(const Duration(hours: 24)),
        );
        if (locked) {
          _toast(
            'You already booked a class and it’s within 24 hours, so you can’t change it.',
          );
          return;
        }

        _setProgressLabel('Saving booking...');

        final cancelStatus = await _cancelBookingByKey(
          cid,
          existingSameTime.dayKey,
          existingSameTime.time,
          existingSameTime.teacherId,
        );
        if (cancelStatus == _CancelBookingStatus.locked) {
          _toast(
            'You already booked a class and it’s within 24 hours, so you can’t change it.',
          );
          return;
        }
        if (cancelStatus == _CancelBookingStatus.failed) {
          _toast('Could not change booking (cancel failed).');
          return;
        }

        final oldSlotStart = _parseSlotStart(
          existingSameTime.dayKey,
          existingSameTime.time,
        );
        if (oldSlotStart != null) {
          try {
            await NotificationService.I.init();
            await NotificationService.I.cancelSessionReminderSeries(
              classId:
                  '${cid}_${existingSameTime.dayKey}_${existingSameTime.time}',
              sessionStart: oldSlotStart,
              minutesBeforeList: _allClassReminderLeadMinutes(),
            );
          } catch (_) {}
        }
      }

      final ref = _reservationsRef(cid, slot.dayKey, slot.time, slot.teacherId);
      _setProgressLabel('Saving booking...');

      final pre = await ref.get();
      int? existingGroupSession;
      int existingCount = 0;

      if (pre.exists && pre.value is Map) {
        final m = (pre.value as Map).map((k, v) => MapEntry(k.toString(), v));
        existingGroupSession = _toInt(m['sessionNo'], fallback: 0);
        if (existingGroupSession <= 0) {
          existingGroupSession = null;
        }

        final learnersRaw = m['learners'];
        if (learnersRaw is Map) {
          existingCount = learnersRaw.length;
          final lm = learnersRaw.map((k, v) => MapEntry(k.toString(), v));
          if (lm.containsKey(myUid)) {
            _toast('You already booked this slot ✅');
            return;
          }
        }
      }

      if (existingGroupSession != null &&
          existingGroupSession != targetSession) {
        _toast(
          'This slot is a Session $existingGroupSession group. You selected Session $targetSession.',
        );
        return;
      }

      final maxCap = slot.maxLearnersPerSlot <= 0 ? 6 : slot.maxLearnersPerSlot;
      if (existingCount >= maxCap) {
        _toast('This slot is full ($maxCap learners).');
        return;
      }

      final tx = await ref.runTransaction((Object? currentData) {
        final Map<String, dynamic> node = (currentData is Map)
            ? currentData.map((k, v) => MapEntry(k.toString(), v))
            : <String, dynamic>{};

        final Map<String, dynamic> learners = <String, dynamic>{};
        final existingLearners = node['learners'];
        if (existingLearners is Map) {
          learners.addAll(
            existingLearners.map((k, v) => MapEntry(k.toString(), v)),
          );
        }

        if (learners.containsKey(myUid)) {
          return Transaction.abort();
        }

        final cap = maxCap;
        if (learners.length >= cap) {
          return Transaction.abort();
        }

        final groupSessionNo = _toInt(node['sessionNo'], fallback: 0);
        if (groupSessionNo > 0 && groupSessionNo != targetSession) {
          return Transaction.abort();
        }

        learners[myUid] = true;

        node['teacherId'] = slot.teacherId;
        node['teacherName'] = slot.teacherName;
        node['sessionNo'] = targetSession;
        node['learners'] = learners;
        node['createdAt'] = ServerValue.timestamp;

        return Transaction.success(node);
      });

      if (!tx.committed) {
        _toast(
          'Booking could not be completed. The class may be full or assigned to another session.',
        );
        return;
      }

      if (existingCount == 0) {
        _toast('Session $targetSession booked successfully.');
      } else {
        _toast('You joined Session $targetSession successfully.');
      }

      _lastBookedStudyMode = studyMode;

      await _sendBookingNotifications(slot, sessionNo: targetSession);
      await _scheduleLearnerLocalReminder(slot);

      await AuditLogService.logSuccess(
        actionKey: AuditActionKeys.learnerBookingCreate,
        domain: AuditDomain.booking,
        summary:
            'Learner booked ${slot.teacherName} ${slot.dayKey} ${slot.time}',
        actor: AuditActor(uid: myUid, role: 'learner'),
        target: AuditTarget(
          type: 'teacher',
          uid: slot.teacherId,
          id: _bookingKey(cid, slot.dayKey, slot.time),
          name: slot.teacherName,
        ),
        keywords: [cid, slot.dayKey, slot.time, '$targetSession'],
        context: {
          'courseId': cid,
          'teacherId': slot.teacherId,
          'dayKey': slot.dayKey,
          'time': slot.time,
          'sessionNo': targetSession,
        },
      );

      await _loadReservationsSummary(cid);
      await _generateSlots(cid);
      await _recomputeRecommendedSessionNo(cid);
      _invalidateBusyRangesCache();
    } catch (e) {
      await AuditLogService.logFailure(
        actionKey: AuditActionKeys.learnerBookingCreate,
        domain: AuditDomain.booking,
        summary: 'Learner booking failed',
        actor: AuditActor(uid: myUid, role: 'learner'),
        target: AuditTarget(
          type: 'teacher',
          uid: slot.teacherId,
          name: slot.teacherName,
        ),
        keywords: [cid, slot.dayKey, slot.time],
        errorMessage: e.toString(),
      );
      _toast('Booking failed: $e');
    } finally {
      if (mounted) {
        setState(() {
          booking = false;
          progressLabel = '';
        });
        _clearBusyVisualIfIdle();
      }
    }
  }

  Future<_CancelBookingStatus> _cancelBookingByKey(
    String cid,
    String dayKey,
    String hhmm,
    String teacherId,
  ) async {
    try {
      final slotStart = _parseSlotStart(dayKey, hhmm);
      if (slotStart == null) {
        return _CancelBookingStatus.failed;
      }
      final locked = !slotStart.isAfter(
        DateTime.now().add(const Duration(hours: 24)),
      );
      if (locked) {
        return _CancelBookingStatus.locked;
      }

      Future<_CancelBookingStatus> cancelAtRef(DatabaseReference ref) async {
        const maxAttempts = 2;

        for (int attempt = 0; attempt < maxAttempts; attempt++) {
          try {
            final result = await ref.runTransaction((Object? currentData) {
              if (currentData is! Map) return Transaction.abort();

              final node = currentData.map((k, v) => MapEntry(k.toString(), v));
              final learnersRaw = node['learners'];
              if (learnersRaw is! Map) return Transaction.abort();

              final learners = learnersRaw.map(
                (k, v) => MapEntry(k.toString(), v),
              );
              if (!learners.containsKey(myUid)) return Transaction.abort();

              learners.remove(myUid);

              if (learners.isEmpty) {
                return Transaction.success(null);
              }

              node['learners'] = learners;
              return Transaction.success(node);
            });

            if (result.committed) {
              return _CancelBookingStatus.cancelled;
            }

            final snap = await ref.get();
            if (!snap.exists || snap.value == null) {
              return _CancelBookingStatus.notFound;
            }

            if (snap.value is! Map) {
              if (attempt < maxAttempts - 1) {
                await Future.delayed(const Duration(milliseconds: 250));
                continue;
              }
              return _CancelBookingStatus.failed;
            }

            final node = (snap.value as Map).map(
              (k, v) => MapEntry(k.toString(), v),
            );
            final learnersRaw = node['learners'];

            if (learnersRaw is Map) {
              final learners = learnersRaw.map(
                (k, v) => MapEntry(k.toString(), v),
              );
              if (!learners.containsKey(myUid)) {
                return _CancelBookingStatus.notFound;
              }
            } else {
              final hasNestedLearners = node.values.any((v) {
                if (v is! Map) return false;
                final vm = v.map((k, vv) => MapEntry(k.toString(), vv));
                return vm['learners'] is Map;
              });
              if (hasNestedLearners) {
                return _CancelBookingStatus.notFound;
              }
            }

            if (attempt < maxAttempts - 1) {
              await Future.delayed(const Duration(milliseconds: 250));
              continue;
            }

            return _CancelBookingStatus.failed;
          } catch (_) {
            if (attempt < maxAttempts - 1) {
              await Future.delayed(const Duration(milliseconds: 250));
              continue;
            }
            return _CancelBookingStatus.failed;
          }
        }

        return _CancelBookingStatus.failed;
      }

      final newRef = _reservationsRef(cid, dayKey, hhmm, teacherId);
      final newStatus = await cancelAtRef(newRef);
      if (newStatus == _CancelBookingStatus.cancelled) {
        return _CancelBookingStatus.cancelled;
      }

      final legacyRef = _legacyReservationsRef(cid, dayKey, hhmm);
      final legacyStatus = await cancelAtRef(legacyRef);
      if (legacyStatus == _CancelBookingStatus.cancelled) {
        return _CancelBookingStatus.cancelled;
      }

      if (newStatus == _CancelBookingStatus.notFound ||
          legacyStatus == _CancelBookingStatus.notFound) {
        return _CancelBookingStatus.notFound;
      }

      return _CancelBookingStatus.failed;
    } catch (_) {
      return _CancelBookingStatus.failed;
    }
  }

  Future<void> _refreshSchedule() async {
    final cid = courseId;
    if (cid == null || loading || booking || refreshing) return;

    setState(() => refreshing = true);
    _markBusyVisualStart();
    try {
      _setProgressLabel('Refreshing schedule...');
      _invalidateBusyRangesCache();
      await _loadStudiedSessions(cid);
      await _loadReservationsSummary(cid);
      await _generateSlots(cid);
      await _recomputeRecommendedSessionNo(cid);
    } finally {
      if (mounted) {
        setState(() {
          refreshing = false;
          progressLabel = '';
        });
        _clearBusyVisualIfIdle();
      }
    }
  }

  Future<void> _cancelUpcomingBooking(String cid, _MyBooking b) async {
    final start = _parseSlotStart(b.dayKey, b.time);
    if (start == null) {
      _toast('Invalid booking time.');
      return;
    }
    final locked = !start.isAfter(
      DateTime.now().add(const Duration(hours: 24)),
    );
    if (locked) {
      _toast('This booking is within 24 hours and cannot be cancelled.');
      return;
    }

    final ok = await _confirmWithLogo(
      title: 'Cancel booking',
      message:
          'Cancel this class with ${b.teacherName} on ${_friendlyDate(start)} at ${b.time}?',
      confirmLabel: 'Yes, Cancel',
      confirmColor: actionOrange,
    );
    if (!mounted || ok != true) return;

    await _runBusy('Cancelling booking...', () async {
      final status = await _cancelBookingByKey(
        cid,
        b.dayKey,
        b.time,
        b.teacherId,
      );
      if (status == _CancelBookingStatus.cancelled) {
        try {
          await NotificationService.I.init();
          await NotificationService.I.cancelSessionReminderSeries(
            classId: '${cid}_${b.dayKey}_${b.time}',
            sessionStart: start,
            minutesBeforeList: _allClassReminderLeadMinutes(),
          );
        } catch (_) {}
        await _sendCancelNotifications(b, cid: cid);
        _toast('Booking cancelled successfully.');
        await _loadReservationsSummary(cid);
        await _generateSlots(cid);
        await _recomputeRecommendedSessionNo(cid);
        _invalidateBusyRangesCache();
        return;
      }
      if (status == _CancelBookingStatus.locked) {
        _toast('This booking is within 24 hours and cannot be cancelled.');
        return;
      }
      if (status == _CancelBookingStatus.notFound) {
        _toast('Booking not found or already cancelled.');
        await _loadReservationsSummary(cid);
        await _generateSlots(cid);
        await _recomputeRecommendedSessionNo(cid);
        return;
      }
      _toast('Could not cancel booking. Please try again.');
    });
  }

  Future<void> _openCancelBookingsSheet() async {
    final cid = courseId;
    if (cid == null || cid.trim().isEmpty) return;
    final items = await _findMyUpcomingBookings(cid);
    final teacherIds = items
        .map((e) => e.teacherId.trim())
        .where((e) => e.isNotEmpty)
        .toSet();
    if (teacherIds.isNotEmpty) {
      await Future.wait(teacherIds.map(_loadTeacherMiniProfile));
    }
    if (!mounted) return;
    final expandedKeys = <String>{};
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            return SafeArea(
              child: FractionallySizedBox(
                heightFactor: 0.86,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(18),
                    ),
                    border: Border.all(color: uiBorder),
                  ),
                  child: Column(
                    children: [
                      const SizedBox(height: 10),
                      Container(
                        width: 42,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.grey.shade300,
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.cancel_outlined,
                              color: actionOrange,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              _cancelSheetTitle(),
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w900,
                                color: primaryBlue,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      Expanded(
                        child: items.isEmpty
                            ? Center(
                                child: Text(
                                  _cancelSheetEmpty(),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              )
                            : ListView.builder(
                                padding: const EdgeInsets.fromLTRB(
                                  12,
                                  4,
                                  12,
                                  12,
                                ),
                                itemCount: items.length,
                                itemBuilder: (_, i) {
                                  final b = items[i];
                                  final rowKey =
                                      '${b.dayKey}|${b.time}|${b.teacherId}';
                                  final expanded = expandedKeys.contains(
                                    rowKey,
                                  );
                                  final mini =
                                      _teacherMiniCache[b.teacherId] ??
                                      _TeacherMiniProfile(
                                        name: b.teacherName,
                                        photoUrl: '',
                                        hasIntroVideo: false,
                                      );
                                  final sessionTitle = b.sessionNo > 0
                                      ? _sessionTitleFor(b.sessionNo)
                                      : '';
                                  final sessionObjective = b.sessionNo > 0
                                      ? _sessionObjectiveFor(b.sessionNo)
                                      : '';
                                  final locked = !b.start.isAfter(
                                    DateTime.now().add(
                                      const Duration(hours: 24),
                                    ),
                                  );

                                  return Container(
                                    margin: const EdgeInsets.only(bottom: 10),
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(color: uiBorder),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                '${_friendlyDate(b.start)} - ${b.time}',
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.w900,
                                                  color: primaryBlue,
                                                ),
                                              ),
                                            ),
                                            InkWell(
                                              borderRadius:
                                                  BorderRadius.circular(999),
                                              onTap: () {
                                                setSheetState(() {
                                                  if (expanded) {
                                                    expandedKeys.remove(rowKey);
                                                  } else {
                                                    expandedKeys.add(rowKey);
                                                  }
                                                });
                                              },
                                              child: Padding(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 6,
                                                      vertical: 4,
                                                    ),
                                                child: Row(
                                                  children: [
                                                    Text(
                                                      _cancelDetailsLabel(
                                                        expanded,
                                                      ),
                                                      style: TextStyle(
                                                        fontSize: 12,
                                                        fontWeight:
                                                            FontWeight.w700,
                                                        color: Colors
                                                            .grey
                                                            .shade700,
                                                      ),
                                                    ),
                                                    const SizedBox(width: 2),
                                                    Icon(
                                                      expanded
                                                          ? Icons
                                                                .keyboard_arrow_up_rounded
                                                          : Icons
                                                                .keyboard_arrow_down_rounded,
                                                      color:
                                                          Colors.grey.shade700,
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 8),
                                        Row(
                                          children: [
                                            ProfileAvatar(
                                              name: mini.name,
                                              photoUrl: mini.photoUrl,
                                              radius: 18,
                                              borderColor: uiBorder,
                                            ),
                                            const SizedBox(width: 8),
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    mini.name,
                                                    style: TextStyle(
                                                      color:
                                                          Colors.grey.shade800,
                                                      fontWeight:
                                                          FontWeight.w800,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 2),
                                                  Text(
                                                    b.sessionNo > 0
                                                        ? _sessionLabel(
                                                            b.sessionNo,
                                                          )
                                                        : 'Session -',
                                                    style: const TextStyle(
                                                      color: primaryBlue,
                                                      fontWeight:
                                                          FontWeight.w900,
                                                      fontSize: 12,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            if (locked)
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 10,
                                                      vertical: 7,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color: Colors.grey.shade200,
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                        999,
                                                      ),
                                                ),
                                                child: Text(
                                                  _cancelLockedLabel(),
                                                  style: const TextStyle(
                                                    fontWeight: FontWeight.w800,
                                                    fontSize: 12,
                                                  ),
                                                ),
                                              )
                                            else
                                              FilledButton(
                                                style: FilledButton.styleFrom(
                                                  backgroundColor: actionOrange,
                                                ),
                                                onPressed: () async {
                                                  Navigator.of(ctx).pop();
                                                  await _cancelUpcomingBooking(
                                                    cid,
                                                    b,
                                                  );
                                                },
                                                child: Text(
                                                  _cancelActionLabel(),
                                                ),
                                              ),
                                          ],
                                        ),
                                        AnimatedSize(
                                          duration: const Duration(
                                            milliseconds: 180,
                                          ),
                                          curve: Curves.easeOut,
                                          child: expanded
                                              ? Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                        top: 10,
                                                      ),
                                                  child: Container(
                                                    width: double.infinity,
                                                    padding:
                                                        const EdgeInsets.all(
                                                          10,
                                                        ),
                                                    decoration: BoxDecoration(
                                                      color: primaryBlue
                                                          .withValues(
                                                            alpha: 0.05,
                                                          ),
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            10,
                                                          ),
                                                      border: Border.all(
                                                        color: uiBorder,
                                                      ),
                                                    ),
                                                    child: Column(
                                                      crossAxisAlignment:
                                                          CrossAxisAlignment
                                                              .start,
                                                      children: [
                                                        if (sessionTitle
                                                            .isNotEmpty) ...[
                                                          Text(
                                                            sessionTitle,
                                                            style:
                                                                const TextStyle(
                                                                  fontWeight:
                                                                      FontWeight
                                                                          .w900,
                                                                  color:
                                                                      primaryBlue,
                                                                ),
                                                          ),
                                                          const SizedBox(
                                                            height: 6,
                                                          ),
                                                        ],
                                                        Text(
                                                          _cancelObjectiveLabel(),
                                                          style: TextStyle(
                                                            fontWeight:
                                                                FontWeight.w800,
                                                            color: Colors
                                                                .grey
                                                                .shade800,
                                                            fontSize: 12,
                                                          ),
                                                        ),
                                                        const SizedBox(
                                                          height: 4,
                                                        ),
                                                        Text(
                                                          sessionObjective
                                                                  .isEmpty
                                                              ? _cancelNoObjectiveLabel()
                                                              : sessionObjective,
                                                          style: TextStyle(
                                                            color: Colors
                                                                .grey
                                                                .shade800,
                                                            fontWeight:
                                                                FontWeight.w600,
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                )
                                              : const SizedBox.shrink(),
                                        ),
                                      ],
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
        );
      },
    );
  }

  Widget _buildCancelEntryCard() {
    final isAr = lessonChoiceArabic;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: _openCancelBookingsSheet,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFB91C1C),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF991B1B)),
        ),
        child: Directionality(
          textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
          child: Row(
            children: [
              const Icon(
                Icons.cancel_schedule_send_rounded,
                color: Colors.white,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: isAr
                      ? CrossAxisAlignment.end
                      : CrossAxisAlignment.start,
                  children: [
                    Text(
                      _cancelCardTitle(),
                      style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _cancelCardSubtitle(),
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.arrow_forward_ios_rounded,
                size: 16,
                color: Colors.white,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ================== Help Sheet ==================

  void _openHowBookingWorks() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (_) {
        final bottomPad = MediaQuery.of(context).padding.bottom;
        final isArabic = helpLang == 'ar';

        return StatefulBuilder(
          builder: (context, setLocalState) {
            return SafeArea(
              child: Padding(
                padding: EdgeInsets.fromLTRB(16, 12, 16, 16 + bottomPad),
                child: Directionality(
                  textDirection: isArabic
                      ? TextDirection.rtl
                      : TextDirection.ltr,
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: isArabic
                          ? CrossAxisAlignment.end
                          : CrossAxisAlignment.start,
                      children: [
                        Text(
                          _helpTitle(helpLang),
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 18,
                            color: primaryBlue,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            _langChip('العربية', 'ar', setLocalState),
                            _langChip('English', 'en', setLocalState),
                            _langChip('Français', 'fr', setLocalState),
                            _langChip('Türkçe', 'tr', setLocalState),
                            _langChip('اردو', 'ur', setLocalState),
                          ],
                        ),
                        const SizedBox(height: 18),
                        _helpStep('1', _helpStep1(helpLang)),
                        _helpStep('2', _helpStep2(helpLang)),
                        _helpStep('3', _helpStep3(helpLang)),
                        _helpStep('4', _helpStep4(helpLang)),
                        const SizedBox(height: 18),
                        Text(
                          _helpRulesTitle(helpLang),
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 15,
                            color: primaryBlue,
                          ),
                        ),
                        const SizedBox(height: 8),
                        _ruleLine(_helpRule1(helpLang)),
                        _ruleLine(_helpRule2(helpLang)),
                        _ruleLine(_helpRule3(helpLang)),
                        _ruleLine(_helpRule4(helpLang)),
                        const SizedBox(height: 18),
                        Text(
                          _helpStatesTitle(helpLang),
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 15,
                            color: primaryBlue,
                          ),
                        ),
                        const SizedBox(height: 8),
                        _stateExplain(
                          bg: emptyBg,
                          border: emptyBorder,
                          label: _helpStateBook(helpLang),
                        ),
                        const SizedBox(height: 8),
                        _stateExplain(
                          bg: peerBg,
                          border: peerBorder,
                          label: _helpStateJoin(helpLang),
                        ),
                        const SizedBox(height: 8),
                        _stateExplain(
                          bg: switchSessionBg,
                          border: switchSessionBorder,
                          label: _helpStateSwitchSession(helpLang),
                        ),
                        const SizedBox(height: 8),
                        _stateExplain(
                          bg: bookedBg,
                          border: bookedBorder,
                          label: _helpStateBooked(helpLang),
                        ),
                        const SizedBox(height: 8),
                        _stateExplain(
                          bg: otherSessionBg,
                          border: otherSessionBorder,
                          label: _helpStateUnavailable(helpLang),
                        ),
                        const SizedBox(height: 8),
                        _stateExplain(
                          bg: lockedBg,
                          border: lockedBorder,
                          label: _helpStateClosed(helpLang),
                        ),
                        const SizedBox(height: 18),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            style: FilledButton.styleFrom(
                              backgroundColor: actionOrange,
                              foregroundColor: Colors.white,
                              minimumSize: const Size.fromHeight(48),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                            onPressed: () => Navigator.pop(context),
                            child: Text(
                              _helpClose(helpLang),
                              style: const TextStyle(
                                fontWeight: FontWeight.w900,
                              ),
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
      },
    );
  }

  void _showClosedSlotInfo() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (_) {
        final bottomPad = MediaQuery.of(context).padding.bottom;
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 16 + bottomPad),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: lockedBg,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(
                          Icons.access_time_rounded,
                          color: Color(0xFFDC2626),
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Text(
                          'Booking Rule',
                          style: TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 18,
                            color: primaryBlue,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: lockedBg,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: lockedBorder),
                    ),
                    child: const Text(
                      '⏰ New bookings close 24 hours before class starts.\n'
                      'You can only join an existing group in the same level during this period.',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                        color: Color(0xFF7C2D12),
                        height: 1.5,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: lockedBg,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: lockedBorder),
                    ),
                    child: const Text(
                      '⏰ الحجوزات الجديدة تُغلق قبل 24 ساعة من بدء الحصة.\n'
                      'يمكنك فقط الانضمام إلى مجموعة موجودة في نفس المستوى خلال هذه الفترة.',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                        color: Color(0xFF7C2D12),
                        height: 1.5,
                      ),
                      textAlign: TextAlign.end,
                      textDirection: TextDirection.rtl,
                    ),
                  ),
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: actionOrange,
                        foregroundColor: Colors.white,
                        minimumSize: const Size.fromHeight(48),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      onPressed: () => Navigator.pop(context),
                      child: const Text(
                        'Got it',
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

  Widget _langChip(
    String label,
    String code,
    void Function(void Function()) setLocalState,
  ) {
    final selected = helpLang == code;
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: () {
        setState(() => helpLang = code);
        setLocalState(() {});
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? actionOrange.withValues(alpha: 0.12) : Colors.white,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected
                ? actionOrange.withValues(alpha: 0.40)
                : uiBorder.withValues(alpha: 0.95),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontWeight: FontWeight.w900,
            color: selected ? actionOrange : primaryBlue,
            fontSize: 12,
          ),
        ),
      ),
    );
  }

  Widget _helpStep(String number, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: actionOrange.withValues(alpha: 0.12),
              shape: BoxShape.circle,
              border: Border.all(color: actionOrange.withValues(alpha: 0.25)),
            ),
            child: Center(
              child: Text(
                number,
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  color: actionOrange,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                color: primaryBlue,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _ruleLine(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        '• $text',
        style: TextStyle(
          fontWeight: FontWeight.w700,
          color: Colors.grey.shade800,
        ),
      ),
    );
  }

  Widget _stateExplain({
    required Color bg,
    required Color border,
    required String label,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                fontWeight: FontWeight.w900,
                color: primaryBlue,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _helpTitle(String lang) {
    switch (lang) {
      case 'ar':
        return 'كيفية الحجز';
      case 'fr':
        return 'Comment réserver';
      case 'tr':
        return 'Nasıl rezervasyon yapılır';
      case 'ur':
        return 'بکنگ کیسے کریں';
      default:
        return 'How booking works';
    }
  }

  String _helpRulesTitle(String lang) {
    switch (lang) {
      case 'ar':
        return 'ملاحظات مهمة';
      case 'fr':
        return 'Règles importantes';
      case 'tr':
        return 'Önemli kurallar';
      case 'ur':
        return 'اہم اصول';
      default:
        return 'Important rules';
    }
  }

  String _helpStatesTitle(String lang) {
    switch (lang) {
      case 'ar':
        return 'معاني الألوان والحالات';
      case 'fr':
        return 'Signification des états';
      case 'tr':
        return 'Durumların anlamı';
      case 'ur':
        return 'اسٹیٹس کا مطلب';
      default:
        return 'What slot labels mean';
    }
  }

  String _helpClose(String lang) {
    switch (lang) {
      case 'ar':
        return 'إغلاق';
      case 'fr':
        return 'Fermer';
      case 'tr':
        return 'Kapat';
      case 'ur':
        return 'بند کریں';
      default:
        return 'Close';
    }
  }

  String _helpStep1(String lang) {
    switch (lang) {
      case 'ar':
        return 'اختر اليوم والوقت المناسبين لك.';
      case 'fr':
        return 'Choisissez le jour et l’heure qui vous conviennent.';
      case 'tr':
        return 'Size uygun gün ve saati seçin.';
      case 'ur':
        return 'اپنے لیے مناسب دن اور وقت منتخب کریں۔';
      default:
        return 'Choose a day and time that works for you.';
    }
  }

  String _helpStep2(String lang) {
    switch (lang) {
      case 'ar':
        return 'اضغط على الحصة لمعرفة التفاصيل.';
      case 'fr':
        return 'Touchez le créneau pour voir les détails.';
      case 'tr':
        return 'Detayları görmek için saate dokunun.';
      case 'ur':
        return 'تفصیلات دیکھنے کے لیے سلاٹ پر ٹیپ کریں۔';
      default:
        return 'Tap a slot to view the details.';
    }
  }

  String _helpStep3(String lang) {
    switch (lang) {
      case 'ar':
        return 'أكد الحجز أو انضم إلى المجموعة إذا كانت من نفس حصتك.';
      case 'fr':
        return 'Confirmez la réservation ou rejoignez le groupe de votre même session.';
      case 'tr':
        return 'Rezervasyonu onaylayın veya aynı oturum grubuna katılın.';
      case 'ur':
        return 'بکنگ کنفرم کریں یا اپنی ہی سیشن گروپ میں شامل ہوں۔';
      default:
        return 'Confirm the booking or join a group from your same session.';
    }
  }

  String _helpStep4(String lang) {
    switch (lang) {
      case 'ar':
        return 'زر الانضمام يظهر قبل وقت الحصة بقليل.';
      case 'fr':
        return 'Le bouton rejoindre apparaît peu avant le cours.';
      case 'tr':
        return 'Katıl düğmesi derse yakın zamanda görünür.';
      case 'ur':
        return 'جوائن بٹن کلاس کے وقت کے قریب ظاہر ہوگا۔';
      default:
        return 'The join button appears near class time.';
    }
  }

  String _helpRule1(String lang) {
    switch (lang) {
      case 'ar':
        return 'يمكنك متابعة الترتيب أو اختيار أي حصة مخصصة من المنهج.';
      case 'fr':
        return 'Vous pouvez suivre la prochaine session ou choisir une session personnalisée.';
      case 'tr':
        return 'Sıradaki oturumu takip edebilir veya istediğiniz oturumu seçebilirsiniz.';
      case 'ur':
        return 'آپ اگلا سیشن فالو کر سکتے ہیں یا اپنی پسند کا سیشن منتخب کر سکتے ہیں۔';
      default:
        return 'You can follow the next session or choose a custom session to study.';
    }
  }

  String _helpRule2(String lang) {
    switch (lang) {
      case 'ar':
        return 'إذا كانت هناك مجموعة من نفس حصتك، يمكنك الانضمام إليها.';
      case 'fr':
        return 'Si un groupe de votre session existe, vous pouvez le rejoindre.';
      case 'tr':
        return 'Aynı oturumda bir grup varsa ona katılabilirsiniz.';
      case 'ur':
        return 'اگر آپ کے سیشن کا گروپ موجود ہے تو آپ اس میں شامل ہو سکتے ہیں۔';
      default:
        return 'If a group from your same session exists, you can join it.';
    }
  }

  String _helpRule3(String lang) {
    switch (lang) {
      case 'ar':
        return 'يمكنك الحجز أو التغيير أو الإلغاء قبل 24 ساعة فقط.';
      case 'fr':
        return 'Vous pouvez réserver, changer ou annuler seulement avant 24 heures.';
      case 'tr':
        return 'Rezervasyon, değişiklik veya iptal sadece 24 saatten önce yapılabilir.';
      case 'ur':
        return 'آپ صرف 24 گھنٹے پہلے بکنگ، تبدیلی یا منسوخی کر سکتے ہیں۔';
      default:
        return 'You can book, change, or cancel only before 24 hours.';
    }
  }

  String _helpRule4(String lang) {
    switch (lang) {
      case 'ar':
        return 'إذا كان المكان ممتلئًا أو لحصة مختلفة أو داخل 24 ساعة، فلن يكون متاحًا.';
      case 'fr':
        return 'Si le créneau est plein, pour une autre session ou dans les 24h, il sera indisponible.';
      case 'tr':
        return 'Saat doluysa, başka oturum içindeyse veya 24 saatten az kaldıysa kullanılamaz.';
      case 'ur':
        return 'اگر سلاٹ بھر گیا ہو، کسی اور سیشن کا ہو، یا 24 گھنٹوں کے اندر ہو تو دستیاب نہیں ہوگا۔';
      default:
        return 'If a slot is full, for another session, or within 24h, it will be unavailable.';
    }
  }

  String _helpStateBook(String lang) {
    switch (lang) {
      case 'ar':
        return 'احجز: الحصة فارغة ويمكنك بدء مجموعة جديدة.';
      case 'fr':
        return 'Réserver : créneau vide, vous pouvez commencer un groupe.';
      case 'tr':
        return 'Rezervasyon: boş saat, yeni grup başlatabilirsiniz.';
      case 'ur':
        return 'بک کریں: خالی سلاٹ، آپ نیا گروپ شروع کر سکتے ہیں۔';
      default:
        return 'Book: empty slot, you can start a new group.';
    }
  }

  String _helpStateJoin(String lang) {
    switch (lang) {
      case 'ar':
        return 'انضم للمجموعة: زملاؤك موجودون بالفعل في هذه الحصة.';
      case 'fr':
        return 'Rejoindre : vos pairs sont déjà dans ce créneau.';
      case 'tr':
        return 'Katıl: arkadaşlarınız bu grupta zaten var.';
      case 'ur':
        return 'گروپ جوائن کریں: آپ کے ساتھی پہلے سے اس گروپ میں ہیں۔';
      default:
        return 'Join group: your peers are already in this slot.';
    }
  }

  String _helpStateBooked(String lang) {
    switch (lang) {
      case 'ar':
        return 'محجوز: أنت بالفعل داخل هذه الحصة.';
      case 'fr':
        return 'Réservé : vous êtes déjà dans ce créneau.';
      case 'tr':
        return 'Rezerve edildi: bu saate zaten dahilsiniz.';
      case 'ur':
        return 'بک ہو چکا: آپ پہلے ہی اس سلاٹ میں شامل ہیں۔';
      default:
        return 'Booked: you are already in this slot.';
    }
  }

  String _helpStateUnavailable(String lang) {
    switch (lang) {
      case 'ar':
        return 'غير متاح: هذه الحصة لمستوى آخر أو ممتلئة.';
      case 'fr':
        return 'Indisponible : autre session ou créneau complet.';
      case 'tr':
        return 'Kullanılamaz: başka oturum ya da dolu.';
      case 'ur':
        return 'دستیاب نہیں: یہ کسی اور سیشن کا ہے یا بھر چکا ہے۔';
      default:
        return 'Unavailable: another level, full, or closed.';
    }
  }

  String _helpStateSwitchSession(String lang) {
    switch (lang) {
      case 'ar':
        return 'انضم مع تغيير الدرس: نفس المستوى لكن درس مختلف.';
      case 'fr':
        return 'Rejoindre en changeant la session : même niveau, session différente.';
      case 'tr':
        return 'Oturumu değiştirerek katıl: aynı seviye, farklı oturum.';
      case 'ur':
        return 'سیشن تبدیل کر کے شامل ہوں: ایک ہی لیول لیکن مختلف سیشن۔';
      default:
        return 'Join with session change: same level, different session.';
    }
  }

  String _helpStateClosed(String lang) {
    switch (lang) {
      case 'ar':
        return 'مغلق: الحجز الجديد يتوقف قبل 24 ساعة، لكن الانضمام لمجموعة نفس المستوى قد يكون متاحاً.';
      case 'fr':
        return 'Fermé : une nouvelle réservation se ferme avant 24h, mais rejoindre un groupe du même niveau peut rester possible.';
      case 'tr':
        return 'Kapalı: yeni rezervasyonlar 24 saat kala kapanır, ancak aynı seviyedeki mevcut gruba katılım mümkün olabilir.';
      case 'ur':
        return 'بند: نئی بکنگ 24 گھنٹے پہلے بند ہو جاتی ہے، لیکن اسی لیول کے موجودہ گروپ میں شامل ہونا ممکن ہو سکتا ہے۔';
      default:
        return 'Closed: new bookings close 24h before class; joining an existing same-level group may still be allowed.';
    }
  }

  // ================== UI ==================

  int get _flowLessonNo => selectedLessonForFlow ?? _targetSessionNo;

  String _sessionLabel(int sessionNo, {String? title}) {
    final t = (title ?? _sessionTitleFor(sessionNo)).trim();
    return t.isEmpty ? 'Session $sessionNo' : 'Session $sessionNo • $t';
  }

  Widget _buildSessionLinePill({
    required String label,
    bool onPrimary = false,
    bool compact = false,
  }) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 10 : 12,
        vertical: compact ? 7 : 9,
      ),
      decoration: BoxDecoration(
        color: onPrimary
            ? Colors.white.withValues(alpha: 0.14)
            : primaryBlue.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: onPrimary
              ? Colors.white.withValues(alpha: 0.28)
              : primaryBlue.withValues(alpha: 0.22),
        ),
      ),
      child: Text(
        label,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontWeight: FontWeight.w900,
          height: 1.2,
          color: onPrimary ? Colors.white : primaryBlue,
          fontSize: compact ? 13 : 14,
        ),
      ),
    );
  }

  List<_Slot> _slotsForCurrentLesson() => List<_Slot>.from(generatedSlots);

  List<DateTime> _availableDaysForLesson() {
    final daysByKey = <String, DateTime>{};
    for (final s in _slotsForCurrentLesson()) {
      daysByKey[s.dayKey] = DateTime(s.start.year, s.start.month, s.start.day);
    }
    final out = daysByKey.values.toList();
    out.sort();
    return out;
  }

  List<String> _availableTimesForDay() {
    if (selectedDay == null) return const [];
    final dk = _dateKey(selectedDay!);
    final set = <String>{};
    for (final s in _slotsForCurrentLesson()) {
      if (s.dayKey != dk) continue;
      set.add(s.time);
    }
    final out = set.toList();
    out.sort();
    return out;
  }

  List<_Slot> _teachersForDayAndTime() {
    if (selectedDay == null || selectedTime == null) return const [];
    final dk = _dateKey(selectedDay!);
    final t = selectedTime!;
    final out = _slotsForCurrentLesson().where((s) {
      return s.dayKey == dk && s.time == t;
    }).toList();
    out.sort((a, b) => a.teacherName.compareTo(b.teacherName));
    return out;
  }

  List<_Slot> _teachersForCurrentLesson() {
    final byTeacher = <String, _Slot>{};
    for (final s in _slotsForCurrentLesson()) {
      byTeacher[s.teacherId] = s;
    }
    final out = byTeacher.values.toList();
    out.sort((a, b) => a.teacherName.compareTo(b.teacherName));
    return out;
  }

  List<DateTime> _availableDaysForTeacher(String teacherId) {
    final daysByKey = <String, DateTime>{};
    for (final s in _slotsForCurrentLesson()) {
      if (s.teacherId != teacherId) continue;
      daysByKey[s.dayKey] = DateTime(s.start.year, s.start.month, s.start.day);
    }
    final out = daysByKey.values.toList();
    out.sort();
    return out;
  }

  List<String> _availableTimesForTeacherDay(String teacherId, DateTime day) {
    final dk = _dateKey(day);
    final set = <String>{};
    for (final s in _slotsForCurrentLesson()) {
      if (s.teacherId != teacherId || s.dayKey != dk) continue;
      set.add(s.time);
    }
    final out = set.toList();
    out.sort();
    return out;
  }

  void _resetScheduleSelections() {
    selectedDay = null;
    selectedTime = null;
    selectedTeacherId = null;
    selectedTeacherFirstId = null;
    confirmSessionNo = null;
    confirmSessionExpanded = false;
  }

  Widget _buildFlowShell(Widget child) {
    final width = MediaQuery.sizeOf(context).width;
    final shellPadding = width >= 900 ? 24.0 : 20.0;
    return Container(
      constraints: const BoxConstraints(maxWidth: 920),
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 10),
      padding: EdgeInsets.all(shellPadding),
      decoration: BoxDecoration(
        color: palette.cardBg.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: palette.border),
      ),
      child: child,
    );
  }

  Widget _buildContinueLearningCard() {
    final recommendedNo = _recommendedSessionNo;
    final recommendedTitle = _sessionTitleFor(recommendedNo);
    final nextObjective = _sessionObjectiveFor(recommendedNo);
    final limitReached = upcomingBookingsCount >= 3;
    final isAr = lessonChoiceArabic;

    return Opacity(
      opacity: limitReached ? 0.56 : 1,
      child: InkWell(
        onTap: limitReached
            ? null
            : () {
                setState(() {
                  studyMode = 'follow';
                  selectedLessonForFlow = recommendedNo;
                  selectedSessionNo = recommendedNo;
                  _resetScheduleSelections();
                  flowStep = _BookingFlowStep.schedule;
                });
              },
        borderRadius: BorderRadius.circular(20),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: const LinearGradient(
              colors: [Color(0xFF0E7C86), Color(0xFF0A5E66)],
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF0E7C86).withValues(alpha: 0.3),
                blurRadius: 12,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: _buildPathwayGraphic()),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('⭐', style: const TextStyle(fontSize: 14)),
                        const SizedBox(width: 4),
                        Text(
                          isAr ? 'موصى به' : 'Recommended',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w900,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                isAr ? 'تابع التعلم' : 'Continue Learning',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  fontSize: 22,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                isAr ? 'تابع من حيث توقفت' : 'continue from where you left',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.85),
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 14),
              _buildSessionLinePill(
                label: _sessionLabel(recommendedNo, title: recommendedTitle),
                onPrimary: true,
              ),
              if (nextObjective.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  nextObjective,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.8),
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                    height: 1.3,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFBF5D39),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: limitReached
                      ? null
                      : () {
                          setState(() {
                            studyMode = 'follow';
                            selectedLessonForFlow = recommendedNo;
                            selectedSessionNo = recommendedNo;
                            _resetScheduleSelections();
                            flowStep = _BookingFlowStep.schedule;
                          });
                        },
                  child: Text(
                    isAr ? '▶ تابع' : '▶ Continue',
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 16,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPathwayGraphic() {
    return SizedBox(
      height: 24,
      child: Row(
        children: List.generate(5, (i) {
          final filled = i < 3;
          return Expanded(
            child: Row(
              children: [
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: filled
                        ? Colors.white
                        : Colors.white.withValues(alpha: 0.35),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.6),
                      width: 2,
                    ),
                  ),
                ),
                if (i < 4)
                  Expanded(
                    child: Container(
                      height: 2,
                      color: filled
                          ? Colors.white.withValues(alpha: 0.7)
                          : Colors.white.withValues(alpha: 0.2),
                    ),
                  ),
              ],
            ),
          );
        }),
      ),
    );
  }

  Widget _buildOrDivider() {
    final isAr = lessonChoiceArabic;
    return Row(
      children: [
        const Expanded(child: Divider(thickness: 1, color: Color(0xFFD8CFC1))),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Text(
            isAr ? 'أو' : 'OR',
            style: TextStyle(
              fontWeight: FontWeight.w900,
              color: palette.text.withValues(alpha: 0.5),
              fontSize: 13,
              letterSpacing: 2,
            ),
          ),
        ),
        const Expanded(child: Divider(thickness: 1, color: Color(0xFFD8CFC1))),
      ],
    );
  }

  Widget _buildChooseLessonSection() {
    final isAr = lessonChoiceArabic;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFD8CFC1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(
              isAr ? 'اختر درساً' : 'Choose a lesson',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 18,
                color: palette.primary,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              isAr
                  ? 'اضغط على درس لمعرفة التفاصيل والحجز'
                  : 'Tap a lesson to see details and book',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 12,
                color: Colors.grey.shade600,
              ),
            ),
          ),
          if (curriculumUnits.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Text(
                isAr ? 'لا توجد دروس متاحة بعد.' : 'No lessons available yet.',
                style: const TextStyle(
                  color: Color(0xFF999999),
                  fontWeight: FontWeight.w700,
                ),
              ),
            )
          else
            ...curriculumUnits.map((unit) => _buildUnitCard(unit)),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  String _unitKey(Map<String, dynamic> unit) {
    final id = (unit['unitId'] ?? '').toString().trim();
    if (id.isNotEmpty) return id;
    return '${unit['unitOrder'] ?? ''}|${unit['unitTitle'] ?? ''}';
  }

  Widget _buildUnitCard(Map<String, dynamic> unit) {
    final isAr = lessonChoiceArabic;
    final unitTitle = (unit['unitTitle'] ?? 'Unit').toString();
    final sessions = (unit['sessions'] as List<Map<String, dynamic>>);
    final total = sessions.length;
    int studied = 0;
    for (final s in sessions) {
      final no = _toInt(s['sessionNo'], fallback: 0);
      if (no > 0 && no < currentSession) studied++;
    }
    final pct = total == 0 ? 0.0 : (studied / total).clamp(0.0, 1.0);
    final completed = total > 0 && studied >= total;
    final started = studied > 0;
    final key = _unitKey(unit);
    final isOpen = _expandedSyllabusObjectives.contains(key);
    final statusText = completed
        ? (isAr ? 'مكتمل' : 'Completed')
        : started
        ? (isAr ? 'قيد التقدم' : 'In progress')
        : (isAr ? 'لم يبدأ' : 'Not started');
    final statusBg = completed
        ? const Color(0xFF0E7C86).withValues(alpha: 0.10)
        : started
        ? const Color(0xFFBF5D39).withValues(alpha: 0.10)
        : const Color(0xFFD8CFC1).withValues(alpha: 0.18);
    final statusFg = completed
        ? const Color(0xFF0E7C86)
        : started
        ? const Color(0xFFBF5D39)
        : const Color(0xFF0E7C86).withValues(alpha: 0.7);

    return Column(
      children: [
        InkWell(
          onTap: () {
            setState(() {
              if (isOpen) {
                _expandedSyllabusObjectives.remove(key);
              } else {
                _expandedSyllabusObjectives.add(key);
              }
            });
          },
          borderRadius: BorderRadius.circular(14),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: isOpen
                    ? const Color(0xFF0E7C86).withValues(alpha: 0.5)
                    : const Color(0xFFD8CFC1).withValues(alpha: 0.75),
              ),
              color: isOpen ? const Color(0xFFF9FCFF) : Colors.white,
            ),
            child: Row(
              children: [
                CircleAvatar(
                  backgroundColor: const Color(
                    0xFF0E7C86,
                  ).withValues(alpha: 0.08),
                  child: Icon(
                    completed
                        ? Icons.verified_rounded
                        : Icons.folder_open_rounded,
                    color: const Color(0xFF0E7C86),
                    size: 20,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        unitTitle,
                        style: const TextStyle(
                          color: Color(0xFF1A1A1A),
                          fontWeight: FontWeight.w900,
                          fontSize: 14,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(999),
                              child: LinearProgressIndicator(
                                value: pct,
                                minHeight: 6,
                                backgroundColor: const Color(
                                  0xFF0E7C86,
                                ).withValues(alpha: 0.08),
                                valueColor: const AlwaysStoppedAnimation(
                                  Color(0xFFBF5D39),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '$studied/$total',
                            style: TextStyle(
                              color: const Color(
                                0xFF1A1A1A,
                              ).withValues(alpha: 0.75),
                              fontWeight: FontWeight.w900,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _miniStatusPill(statusText, statusBg, statusFg),
                const SizedBox(width: 4),
                Icon(
                  isOpen
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  color: const Color(0xFF0E7C86),
                  size: 22,
                ),
              ],
            ),
          ),
        ),
        if (isOpen)
          Container(
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 6),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: const Color(0xFFD8CFC1).withValues(alpha: 0.85),
              ),
              color: const Color(0xFFFAFBFC),
            ),
            child: Column(
              children: sessions.map((s) => _buildLessonRow(s)).toList(),
            ),
          ),
      ],
    );
  }

  Widget _miniStatusPill(String text, Color bg, Color fg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(fontWeight: FontWeight.w800, color: fg, fontSize: 10),
      ),
    );
  }

  void _openSessionBookingSheet(Map<String, dynamic> session) {
    final no = _toInt(session['sessionNo'], fallback: 0);
    final title = (session['sessionTitle'] ?? '').toString().trim();
    final objective = (session['objective'] ?? '').toString().trim();
    final isAr = lessonChoiceArabic;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => Padding(
        padding: EdgeInsets.only(
          bottom:
              MediaQuery.of(context).viewInsets.bottom +
              MediaQuery.of(context).padding.bottom,
        ),
        child: Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
          ),
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
          child: SingleChildScrollView(
            child: Directionality(
              textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 44,
                    height: 5,
                    margin: const EdgeInsets.only(bottom: 14),
                    decoration: BoxDecoration(
                      color: const Color(0xFFDDE4EA),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  Row(
                    textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
                    children: [
                      Icon(
                        Icons.menu_book_rounded,
                        color: const Color(0xFF0E7C86),
                        size: 24,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          title.isEmpty
                              ? 'Session $no'
                              : 'Session $no — $title',
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 18,
                            color: Color(0xFF0E7C86),
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (objective.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    Text(
                      isAr ? 'هدف الحصة' : 'Session Objective',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 12,
                        color: Colors.grey.shade600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      objective,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF1A1A1A),
                        height: 1.35,
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFBF5D39),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: () {
                        Navigator.of(context).pop();
                        setState(() {
                          studyMode = 'custom';
                          selectedLessonForFlow = no;
                          selectedSessionNo = no;
                          _resetScheduleSelections();
                          flowStep = _BookingFlowStep.schedule;
                        });
                      },
                      child: Text(
                        isAr ? 'احجز هذه الحصة' : 'Book this session',
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showSessionMiniDetailsForLesson(Map<String, dynamic> session) {
    final no = _toInt(session['sessionNo'], fallback: 0);
    final objective = (session['objective'] ?? '').toString().trim();
    final title = (session['sessionTitle'] ?? '').toString().trim();
    final isAr = lessonChoiceArabic;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
        padding: EdgeInsets.only(
          bottom:
              MediaQuery.of(context).viewInsets.bottom +
              MediaQuery.of(context).padding.bottom,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 44,
                  height: 5,
                  margin: const EdgeInsets.only(bottom: 14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFDDE4EA),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                Row(
                  children: [
                    Icon(
                      Icons.info_outline_rounded,
                      color: primaryBlue,
                      size: 22,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        title.isEmpty ? 'Session $no' : 'Session $no — $title',
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 18,
                          color: primaryBlue,
                        ),
                      ),
                    ),
                  ],
                ),
                if (objective.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Text(
                    isAr ? 'هدف الحصة' : 'Session Objective',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                      color: Colors.grey.shade600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    objective,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF1A1A1A),
                      height: 1.35,
                    ),
                  ),
                ],
                if (objective.isEmpty) ...[
                  const SizedBox(height: 14),
                  Text(
                    isAr
                        ? 'لا توجد تفاصيل إضافية لهذه الحصة.'
                        : 'No additional details for this session.',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: Colors.grey.shade600,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLessonRow(Map<String, dynamic> session) {
    final no = _toInt(session['sessionNo'], fallback: 0);
    final title = (session['sessionTitle'] ?? '').toString().trim();
    final label = title.isEmpty ? 'Session $no' : 'Session $no • $title';
    final studied = no > 0 && no < currentSession;
    final isNext = no == currentSession;
    final isAvailable = no > currentSession;
    final limitReached = upcomingBookingsCount >= 3;

    IconData icon;
    Color iconColor;
    if (studied) {
      icon = Icons.check_circle_rounded;
      iconColor = const Color(0xFF0E7C86);
    } else if (isNext) {
      icon = Icons.play_circle_filled_rounded;
      iconColor = const Color(0xFFBF5D39);
    } else {
      icon = Icons.menu_book_rounded;
      iconColor = const Color(0xFF0E7C86).withValues(alpha: 0.55);
    }

    return InkWell(
      onTap: (isNext || isAvailable) && !limitReached
          ? () => _openSessionBookingSheet(session)
          : null,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: studied
                ? const Color(0xFF0E7C86).withValues(alpha: 0.24)
                : const Color(0xFFD8CFC1).withValues(alpha: 0.75),
          ),
          color: studied
              ? const Color(0xFF0E7C86).withValues(alpha: 0.03)
              : Colors.white,
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: iconColor),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  color: Color(0xFF1A1A1A),
                  fontWeight: FontWeight.w800,
                  fontSize: 13,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 6),
            if (!studied)
              GestureDetector(
                onTap: () => _showSessionMiniDetailsForLesson(session),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(
                    Icons.info_outline_rounded,
                    size: 16,
                    color: const Color(0xFF0E7C86).withValues(alpha: 0.55),
                  ),
                ),
              ),
            const Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: Color(0xFF0E7C86),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLessonChoiceStep() {
    final limitReached = upcomingBookingsCount >= 3;
    const maxBookings = 3;
    final used = upcomingBookingsCount;
    final isAr = lessonChoiceArabic;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (upcomingBookingsCount > 0) _buildCancelEntryCard(),
        const SizedBox(height: 20),
        Icon(Icons.auto_awesome_rounded, size: 36, color: palette.primary),
        const SizedBox(height: 10),
        Center(
          child: Text(
            isAr ? 'ماذا تريد أن تتعلم؟' : 'What would you like to learn?',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w900,
              color: palette.primary,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          isAr
              ? 'تابع مسارك الموصى به، أو اختر درساً بنفسك.'
              : 'continue your recommended path, or choose a lesson yourself.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: palette.text.withValues(alpha: 0.65),
          ),
        ),
        if (used > 0) ...[
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: Text(
                  isAr
                      ? '$used من $maxBookings حجوزات مستخدمة'
                      : '$used of $maxBookings bookings used',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: palette.text.withValues(alpha: 0.8),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: used / maxBookings,
              minHeight: 6,
              backgroundColor: palette.soft,
              valueColor: AlwaysStoppedAnimation<Color>(
                used >= maxBookings ? actionOrange : palette.primary,
              ),
            ),
          ),
        ],
        const SizedBox(height: 22),
        _buildContinueLearningCard(),
        const SizedBox(height: 20),
        _buildOrDivider(),
        const SizedBox(height: 20),
        _buildChooseLessonSection(),
        if (limitReached) ...[
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFFFEFEA),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFF2B8A8)),
            ),
            child: Text(
              _bookingLimitNote(),
              style: const TextStyle(
                color: Color(0xFF8A3D27),
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _onBookAnother() async {
    final cid = courseId;
    if (cid == null) return;
    await _refreshSchedule();
    if (!mounted) return;

    final wasFollowMode = _lastBookedStudyMode == 'follow';
    final wasCustomMode = _lastBookedStudyMode == 'custom';

    setState(() {
      selectedDay = null;
      selectedTime = null;
      selectedTeacherId = null;
      selectedTeacherFirstId = null;
      selectedLessonForFlow = null;
      confirmSessionExpanded = false;
      schedulePath = _SchedulePath.byTeacher;

      if (wasFollowMode) {
        selectedSessionNo = _recommendedSessionNo;
        studyMode = 'follow';
        flowStep = _BookingFlowStep.lessonChoice;
      } else if (wasCustomMode) {
        studyMode = 'custom';
        flowStep = _BookingFlowStep.lessonChoice;
      } else {
        flowStep = _BookingFlowStep.lessonChoice;
      }
    });
  }

  Widget _buildSchedulePathPill({
    required _SchedulePath path,
    required IconData icon,
    required String label,
    bool fullWidth = true,
  }) {
    final isAr = lessonChoiceArabic;
    final selected = schedulePath == path;
    Widget buildPill({required bool expand}) {
      return InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: () {
          if (schedulePath == path) return;
          setState(() {
            schedulePath = path;
            _resetScheduleSelections();
          });
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: selected ? palette.primary : Colors.white,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: selected ? palette.primary : uiBorder),
          ),
          child: Row(
            textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 18,
                color: selected ? Colors.white : palette.primary,
              ),
              const SizedBox(width: 8),
              if (expand)
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      color: selected ? Colors.white : palette.primary,
                    ),
                  ),
                )
              else
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      color: selected ? Colors.white : palette.primary,
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    }

    if (!fullWidth) return buildPill(expand: false);
    return Expanded(child: buildPill(expand: true));
  }

  Widget _buildStepLabel(
    int no,
    String text, {
    int totalSteps = 3,
    String? hint,
  }) {
    final isAr = lessonChoiceArabic;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: primaryBlue,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Center(
                child: Text(
                  '$no',
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    color: Colors.white,
                    fontSize: 13,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  color: primaryBlue,
                  fontSize: 15,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: primaryBlue.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: primaryBlue.withValues(alpha: 0.2)),
              ),
              child: Text(
                '$no/$totalSteps',
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  color: primaryBlue,
                  fontSize: 11,
                ),
              ),
            ),
          ],
        ),
        if (hint != null && hint.isNotEmpty) ...[
          const SizedBox(height: 6),
          Padding(
            padding: EdgeInsets.only(left: isAr ? 0 : 38, right: isAr ? 38 : 0),
            child: Text(
              hint,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade600,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildStepCard({
    required Widget child,
    required bool isActive,
    required bool isCompleted,
  }) {
    return AnimatedBuilder(
      animation: _sessionPulseCtrl,
      builder: (context, _) {
        final pulse = isActive ? _sessionPulseCtrl.value : 0.0;
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 14),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: isActive
                ? primaryBlue.withValues(alpha: 0.05 + (pulse * 0.03))
                : isCompleted
                ? primaryBlue.withValues(alpha: 0.03)
                : Colors.grey.withValues(alpha: 0.03),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isActive
                  ? primaryBlue.withValues(alpha: 0.25 + (pulse * 0.2))
                  : isCompleted
                  ? primaryBlue.withValues(alpha: 0.15)
                  : Colors.grey.withValues(alpha: 0.15),
            ),
            boxShadow: isActive
                ? [
                    BoxShadow(
                      color: primaryBlue.withValues(
                        alpha: 0.08 + (pulse * 0.08),
                      ),
                      blurRadius: 6 + (pulse * 4),
                      offset: const Offset(0, 2),
                    ),
                  ]
                : [],
          ),
          child: child,
        );
      },
      child: child,
    );
  }

  Widget _buildTimeChip(
    String t,
    bool selected,
    VoidCallback onTap, {
    _SlotStatus status = _SlotStatus.availableBook,
    String? label,
    bool pulse = false,
    VoidCallback? onDetailsTap,
  }) {
    Color bg = emptyBg;
    Color border = emptyBorder;
    Color fg = primaryBlue;
    switch (status) {
      case _SlotStatus.booked:
        bg = bookedBg;
        border = bookedBorder;
        break;
      case _SlotStatus.joinSameSession:
        bg = exactMatchBg;
        border = exactMatchBorder;
        break;
      case _SlotStatus.joinWithSessionChange:
        bg = switchSessionBg;
        border = switchSessionBorder;
        break;
      case _SlotStatus.unavailable:
        bg = otherSessionBg;
        border = otherSessionBorder;
        fg = Colors.grey.shade700;
        break;
      case _SlotStatus.closed:
        bg = lockedBg;
        border = lockedBorder;
        fg = const Color(0xFFDC2626);
        break;
      case _SlotStatus.availableBook:
        break;
    }

    final child = AnimatedContainer(
      duration: const Duration(milliseconds: 170),
      curve: Curves.easeOut,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: selected ? primaryBlue : bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: selected ? primaryBlue : border),
        boxShadow: selected
            ? const [
                BoxShadow(
                  color: Color(0x1A0E7C86),
                  blurRadius: 10,
                  offset: Offset(0, 4),
                ),
              ]
            : pulse
            ? [
                BoxShadow(
                  color: border.withValues(
                    alpha: 0.18 + (_sessionPulseCtrl.value * 0.2),
                  ),
                  blurRadius: 10 + (_sessionPulseCtrl.value * 6),
                  offset: const Offset(0, 2),
                ),
              ]
            : const [],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              label ?? t,
              style: TextStyle(
                fontWeight: FontWeight.w900,
                color: selected ? Colors.white : fg,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (onDetailsTap != null) ...[
            const SizedBox(width: 8),
            GestureDetector(
              onTap: onDetailsTap,
              behavior: HitTestBehavior.opaque,
              child: Icon(
                Icons.arrow_forward_ios_rounded,
                size: 14,
                color: selected ? Colors.white : fg,
              ),
            ),
          ],
        ],
      ),
    );

    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: pulse
          ? AnimatedBuilder(
              animation: _sessionPulseCtrl,
              builder: (_, __) => Transform.scale(
                scale: 1 + (_sessionPulseCtrl.value * 0.02),
                child: child,
              ),
            )
          : child,
    );
  }

  Widget _slotStateBadge(_SlotStatus status) {
    final isAr = lessonChoiceArabic;
    final label = switch (status) {
      _SlotStatus.joinSameSession => isAr ? 'انضمام' : 'Join',
      _SlotStatus.joinWithSessionChange =>
        isAr ? 'انضمام + تبديل' : 'Join + switch',
      _SlotStatus.booked => isAr ? 'محجوز' : 'Booked',
      _SlotStatus.unavailable => isAr ? 'غير متاح' : 'Unavailable',
      _SlotStatus.closed => isAr ? 'مغلق' : 'Closed',
      _SlotStatus.availableBook => isAr ? 'احجز' : 'Book',
    };
    final bg = switch (status) {
      _SlotStatus.joinSameSession => peerBg,
      _SlotStatus.joinWithSessionChange => switchSessionBg,
      _SlotStatus.booked => bookedBg,
      _SlotStatus.unavailable => otherSessionBg,
      _SlotStatus.closed => lockedBg,
      _SlotStatus.availableBook => emptyBg,
    };
    final border = switch (status) {
      _SlotStatus.joinSameSession => peerBorder,
      _SlotStatus.joinWithSessionChange => switchSessionBorder,
      _SlotStatus.booked => bookedBorder,
      _SlotStatus.unavailable => otherSessionBorder,
      _SlotStatus.closed => lockedBorder,
      _SlotStatus.availableBook => emptyBorder,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: border),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontWeight: FontWeight.w800,
          fontSize: 11,
          color: primaryBlue,
        ),
      ),
    );
  }

  Widget _buildScheduleHeader() {
    final isAr = lessonChoiceArabic;
    return Directionality(
      textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: uiBorder),
          boxShadow: const [
            BoxShadow(
              color: Color(0x14000000),
              blurRadius: 20,
              offset: Offset(0, 10),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: primaryBlue.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(Icons.book_rounded, color: primaryBlue, size: 18),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    courseTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      color: primaryBlue,
                      fontSize: 18,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _buildSessionLinePill(label: _sessionLabel(_flowLessonNo)),
            const SizedBox(height: 6),
            Text(
              'Session $_flowLessonNo of $_effectiveTotalSessions',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: Colors.grey.shade600,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: actionOrange,
                  side: BorderSide(color: actionOrange.withValues(alpha: 0.4)),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 11,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                onPressed: () =>
                    setState(() => flowStep = _BookingFlowStep.lessonChoice),
                icon: const Icon(Icons.arrow_back_rounded, size: 16),
                label: Text(
                  isAr ? 'تغيير الدرس' : 'Change lesson',
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCalendarDayGrid({
    required List<DateTime> days,
    required DateTime? selectedDay,
    required void Function(DateTime) onDaySelected,
    String? teacherId,
  }) {
    if (days.isEmpty) return const SizedBox.shrink();
    final sorted = List<DateTime>.from(days)..sort();
    final firstMonth = DateTime(sorted.first.year, sorted.first.month, 1);
    final lastMonth = DateTime(sorted.last.year, sorted.last.month, 1);
    final months = <DateTime>[];
    var m = firstMonth;
    while (!m.isAfter(lastMonth)) {
      months.add(m);
      m = DateTime(m.year, m.month + 1, 1);
    }
    return Column(
      children: [
        const SizedBox(height: 8),
        for (final month in months)
          _buildMonthGrid(
            month: month,
            sortedDays: sorted,
            selectedDay: selectedDay,
            onDaySelected: onDaySelected,
            teacherId: teacherId,
          ),
      ],
    );
  }

  Widget _buildMonthGrid({
    required DateTime month,
    required List<DateTime> sortedDays,
    required DateTime? selectedDay,
    required void Function(DateTime) onDaySelected,
    required String? teacherId,
  }) {
    final isAr = lessonChoiceArabic;
    final monthDays = sortedDays
        .where((d) => d.year == month.year && d.month == month.month)
        .toSet()
        .toList();
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    final firstWeekday = DateTime(month.year, month.month, 1).weekday;
    final startOffset = firstWeekday - 1;

    final weekdayLabels = isAr
        ? ['ح', 'ن', 'ث', 'ر', 'خ', 'ج', 'س']
        : ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const monthNames = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];

    return Column(
      children: [
        const SizedBox(height: 8),
        Text(
          '${monthNames[month.month - 1]} ${month.year}',
          style: const TextStyle(
            fontWeight: FontWeight.w900,
            color: primaryBlue,
            fontSize: 15,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: weekdayLabels
              .map(
                (l) => Expanded(
                  child: Center(
                    child: Text(
                      l,
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 11,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ),
                ),
              )
              .toList(),
        ),
        const SizedBox(height: 4),
        ..._buildWeeks(
          month: month,
          daysInMonth: daysInMonth,
          startOffset: startOffset,
          monthDays: monthDays,
          selectedDay: selectedDay,
          onDaySelected: onDaySelected,
          teacherId: teacherId,
        ),
        const SizedBox(height: 4),
      ],
    );
  }

  List<Widget> _buildWeeks({
    required DateTime month,
    required int daysInMonth,
    required int startOffset,
    required List<DateTime> monthDays,
    required DateTime? selectedDay,
    required void Function(DateTime) onDaySelected,
    required String? teacherId,
  }) {
    final weeks = <Widget>[];
    var day = 1;
    while (day <= daysInMonth) {
      final cells = <Widget>[];
      for (var col = 0; col < 7; col++) {
        if ((day == 1 && col < startOffset) || day > daysInMonth) {
          cells.add(const Expanded(child: SizedBox(height: 42)));
        } else {
          final currentDay = DateTime(month.year, month.month, day);
          final isAvailable = monthDays.any((d) => d.day == currentDay.day);
          final isSelected =
              selectedDay != null &&
              selectedDay.day == currentDay.day &&
              selectedDay.month == currentDay.month &&
              selectedDay.year == currentDay.year;
          final summary = isAvailable
              ? _daySlotSummary(currentDay, teacherId: teacherId)
              : _DaySlotSummary.none;

          cells.add(
            Expanded(
              child: _buildCalendarCell(
                dayNumber: day,
                isAvailable: isAvailable,
                isSelected: isSelected,
                summary: summary,
                onTap: isAvailable ? () => onDaySelected(currentDay) : null,
              ),
            ),
          );
          day++;
        }
      }
      weeks.add(Row(mainAxisSize: MainAxisSize.min, children: cells));
    }
    return weeks;
  }

  Widget _buildCalendarCell({
    required int dayNumber,
    required bool isAvailable,
    required bool isSelected,
    required _DaySlotSummary summary,
    required VoidCallback? onTap,
  }) {
    final bool showDot = isAvailable && summary != _DaySlotSummary.none;
    final Color dotColor;
    if (summary == _DaySlotSummary.available) {
      dotColor = const Color(0xFF22C55E);
    } else if (summary == _DaySlotSummary.groupOnly) {
      dotColor = const Color(0xFFF97316);
    } else {
      dotColor = Colors.grey;
    }

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        height: 42,
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: isSelected ? primaryBlue : null,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '$dayNumber',
              style: TextStyle(
                fontWeight: isSelected || isAvailable
                    ? FontWeight.w900
                    : FontWeight.w600,
                color: isSelected
                    ? Colors.white
                    : isAvailable
                    ? primaryBlue
                    : Colors.grey.shade400,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 2),
            if (showDot)
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: dotColor,
                ),
              )
            else
              const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }

  Widget _buildByTeacherPath() {
    final isAr = lessonChoiceArabic;
    final teachers = _teachersForCurrentLesson();
    final hasRecommendations = _recommendedMatchSlots().isNotEmpty;
    final shouldCollapseTeachers =
        hasRecommendations && (_teachersCollapsed || !_teachersCollapseTouched);
    final days = selectedTeacherFirstId == null
        ? const <DateTime>[]
        : _availableDaysForTeacher(selectedTeacherFirstId!);
    final times = (selectedTeacherFirstId == null || selectedDay == null)
        ? const <String>[]
        : _availableTimesForTeacherDay(selectedTeacherFirstId!, selectedDay!);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildStepCard(
          isActive: selectedTeacherFirstId == null,
          isCompleted: selectedTeacherFirstId != null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildStepLabel(
                1,
                isAr ? 'اختر معلم' : 'Choose a teacher',
                hint: isAr
                    ? 'انقر على معلم لرؤية الأيام المتاحة'
                    : 'Tap a teacher to see available days',
              ),
              const SizedBox(height: 8),
              if (shouldCollapseTeachers)
                _collapsedTeachersCard(teachers)
              else
                ...teachers.map((s) {
                  final selected = selectedTeacherFirstId == s.teacherId;
                  final cap = s.maxLearnersPerSlot <= 0
                      ? 6
                      : s.maxLearnersPerSlot;
                  final booked = _effectiveBookedCount(s);
                  final left = (cap - booked) < 0 ? 0 : (cap - booked);
                  final status = _slotStatus(s, sessionNo: _flowLessonNo);
                  final canSelect =
                      status != _SlotStatus.unavailable &&
                      status != _SlotStatus.closed &&
                      status != _SlotStatus.booked;
                  final tint = _teacherTint(s.teacherId);
                  return InkWell(
                    borderRadius: BorderRadius.circular(14),
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: selected ? tint.withValues(alpha: 0.42) : tint,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: selected
                              ? primaryBlue
                              : tint.withValues(alpha: 0.9),
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: InkWell(
                              borderRadius: BorderRadius.circular(10),
                              onTap: () => _openTeacherProfileSheet(s),
                              child: Row(
                                children: [
                                  ProfileAvatar(
                                    name: s.teacherName,
                                    photoUrl: s.teacherPhotoUrl,
                                    radius: 19,
                                    borderColor: Colors.white.withValues(
                                      alpha: 0.9,
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          s.teacherName,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w900,
                                            color: primaryBlue,
                                          ),
                                        ),
                                        const SizedBox(height: 3),
                                        Wrap(
                                          spacing: 8,
                                          runSpacing: 6,
                                          crossAxisAlignment:
                                              WrapCrossAlignment.center,
                                          children: [
                                            Text(
                                              status ==
                                                      _SlotStatus
                                                          .joinWithSessionChange
                                                  ? '$left seats • Session ${_effectiveGroupSessionNo(s) ?? '-'}'
                                                  : '$left seats available',
                                              style: TextStyle(
                                                fontWeight: FontWeight.w700,
                                                color: Colors.grey.shade700,
                                              ),
                                            ),
                                            if (s.hasIntroVideo)
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 6,
                                                      vertical: 2,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color: Colors.white
                                                      .withValues(alpha: 0.8),
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                        999,
                                                      ),
                                                ),
                                                child: const Text(
                                                  'Video',
                                                  style: TextStyle(
                                                    fontSize: 11,
                                                    fontWeight: FontWeight.w800,
                                                    color: primaryBlue,
                                                  ),
                                                ),
                                              ),
                                            _slotStateBadge(status),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            style: FilledButton.styleFrom(
                              backgroundColor: actionOrange,
                            ),
                            onPressed: canSelect
                                ? () {
                                    setState(() {
                                      selectedTeacherFirstId = s.teacherId;
                                      selectedTeacherId = s.teacherId;
                                      selectedDay = null;
                                      selectedTime = null;
                                    });
                                    _scrollTo(_byTeacherSelectionKey);
                                  }
                                : null,
                            child: Text(
                              selected
                                  ? (isAr ? 'مختار' : 'Selected')
                                  : (canSelect
                                        ? (isAr ? 'اختيار' : 'Select')
                                        : (isAr ? 'مقفول' : 'Locked')),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
            ],
          ),
        ),
        if (selectedTeacherFirstId != null)
          _buildStepCard(
            isActive: selectedDay == null,
            isCompleted: selectedDay != null,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(key: _byTeacherSelectionKey),
                _buildStepLabel(
                  2,
                  isAr ? 'اختر يوم' : 'Choose a day',
                  hint: isAr
                      ? 'اختر يوماً لعرض الأوقات المتاحة'
                      : 'Pick a day to see available times',
                ),
                const SizedBox(height: 6),
                _buildCalendarDayGrid(
                  days: days,
                  selectedDay: selectedDay,
                  onDaySelected: (d) {
                    setState(() {
                      selectedDay = d;
                      selectedTime = null;
                    });
                    _scrollTo(_timeStepKey);
                  },
                  teacherId: selectedTeacherFirstId,
                ),
              ],
            ),
          ),
        if (selectedDay != null)
          _buildStepCard(
            isActive: selectedTime == null,
            isCompleted: selectedTime != null,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(key: _timeStepKey),
                _buildStepLabel(
                  3,
                  isAr ? 'اختر وقت' : 'Choose a time',
                  hint: isAr
                      ? 'اختر وقتاً مناسباً للمتابعة'
                      : 'Choose a suitable time to proceed',
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final t in times)
                      _buildTimeChip(
                        t,
                        selectedTime == t,
                        () {
                          final slot = _slotsForCurrentLesson().firstWhere(
                            (s) =>
                                s.teacherId == selectedTeacherFirstId &&
                                s.dayKey == _dateKey(selectedDay!) &&
                                s.time == t,
                          );
                          final status = _slotStatus(
                            slot,
                            sessionNo: _flowLessonNo,
                          );
                          if (status == _SlotStatus.closed) {
                            _showClosedSlotInfo();
                            return;
                          }
                          if (status == _SlotStatus.unavailable ||
                              status == _SlotStatus.booked) {
                            _toast(_blockedSlotToast(slot));
                            return;
                          }
                          setState(() {
                            selectedTime = t;
                          });
                        },
                        status: () {
                          final slot = _slotsForCurrentLesson().firstWhere(
                            (s) =>
                                s.teacherId == selectedTeacherFirstId &&
                                s.dayKey == _dateKey(selectedDay!) &&
                                s.time == t,
                          );
                          return _slotStatus(slot, sessionNo: _flowLessonNo);
                        }(),
                        label: () {
                          final slot = _slotsForCurrentLesson().firstWhere(
                            (s) =>
                                s.teacherId == selectedTeacherFirstId &&
                                s.dayKey == _dateKey(selectedDay!) &&
                                s.time == t,
                          );
                          final kind = _chipMatchKindForSlot(
                            slot,
                            targetSession: _flowLessonNo,
                          );
                          if (kind == _ChipMatchKind.none) {
                            return _timeChipLabel(
                              t,
                              _slotStatus(slot, sessionNo: _flowLessonNo),
                              slot: slot,
                            );
                          }
                          return _timeChipDetailsLabel(
                            slot,
                            targetSession: _flowLessonNo,
                          );
                        }(),
                        pulse: () {
                          final slot = _slotsForCurrentLesson().firstWhere(
                            (s) =>
                                s.teacherId == selectedTeacherFirstId &&
                                s.dayKey == _dateKey(selectedDay!) &&
                                s.time == t,
                          );
                          return _chipMatchKindForSlot(
                                slot,
                                targetSession: _flowLessonNo,
                              ) !=
                              _ChipMatchKind.none;
                        }(),
                        onDetailsTap: () {
                          final slot = _slotsForCurrentLesson().firstWhere(
                            (s) =>
                                s.teacherId == selectedTeacherFirstId &&
                                s.dayKey == _dateKey(selectedDay!) &&
                                s.time == t,
                          );
                          _showSessionMiniDetails(slot);
                        },
                      ),
                  ],
                ),
                ...() {
                  final suggestions = _suggestedSlotsForTeacherDay();
                  if (suggestions.isEmpty) return <Widget>[];
                  return [
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Icon(
                          Icons.tips_and_updates_rounded,
                          color: Colors.lightBlue.shade700,
                          size: 18,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          isAr
                              ? 'مقترح (نفس المستوى)'
                              : 'Suggested (same level)',
                          style: TextStyle(
                            fontWeight: FontWeight.w900,
                            color: Colors.lightBlue.shade800,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    ...suggestions.map((s) {
                      final status = _slotStatus(s, sessionNo: _flowLessonNo);
                      final session =
                          _effectiveGroupSessionNo(s) ?? _flowLessonNo;
                      return InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () {
                          setState(() {
                            selectedTeacherId = s.teacherId;
                            selectedTeacherFirstId = s.teacherId;
                            selectedDay = DateTime(
                              s.start.year,
                              s.start.month,
                              s.start.day,
                            );
                            selectedTime = s.time;
                            confirmSessionNo =
                                status == _SlotStatus.joinWithSessionChange
                                ? session
                                : _flowLessonNo;
                            flowStep = _BookingFlowStep.confirm;
                          });
                        },
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: Colors.lightBlue.shade50,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: Colors.lightBlue.shade200,
                            ),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      s.teacherName,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w900,
                                        color: primaryBlue,
                                        fontSize: 13,
                                      ),
                                    ),
                                    const SizedBox(height: 3),
                                    Text(
                                      isAr
                                          ? '${s.time} • جلسة $session'
                                          : '${s.time} • Session $session',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                        color: Colors.grey.shade700,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color:
                                      status ==
                                          _SlotStatus.joinWithSessionChange
                                      ? switchSessionBg
                                      : peerBg,
                                  borderRadius: BorderRadius.circular(999),
                                  border: Border.all(
                                    color:
                                        status ==
                                            _SlotStatus.joinWithSessionChange
                                        ? switchSessionBorder
                                        : peerBorder,
                                  ),
                                ),
                                child: Text(
                                  status == _SlotStatus.joinWithSessionChange
                                      ? (isAr
                                            ? 'انضمام + تبديل'
                                            : 'Join + switch')
                                      : (isAr ? 'انضمام' : 'Join'),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                    color: primaryBlue,
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }),
                  ];
                }(),
                if (selectedTime != null) ...[
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: actionOrange,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: () => setState(() {
                      confirmSessionNo = _flowLessonNo;
                      flowStep = _BookingFlowStep.confirm;
                    }),
                    icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                    label: Text(
                      isAr ? 'متابعة للتأكيد' : 'Continue to confirm',
                    ),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildByDayPath() {
    final isAr = lessonChoiceArabic;
    final days = _availableDaysForLesson();
    final times = _availableTimesForDay();
    final teachers = _teachersForDayAndTime();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildStepCard(
          isActive: selectedDay == null,
          isCompleted: selectedDay != null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildStepLabel(
                1,
                isAr ? 'اختر يوم' : 'Choose a day',
                hint: isAr
                    ? 'اختر يوماً لعرض الأوقات المتاحة'
                    : 'Pick a day to see available times',
              ),
              const SizedBox(height: 6),
              _buildCalendarDayGrid(
                days: days,
                selectedDay: selectedDay,
                onDaySelected: (d) {
                  setState(() {
                    selectedDay = d;
                    selectedTime = null;
                    selectedTeacherId = null;
                  });
                  _scrollTo(_timeStepKey);
                },
              ),
            ],
          ),
        ),
        if (selectedDay != null)
          _buildStepCard(
            isActive: selectedTime == null,
            isCompleted: selectedTime != null,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(key: _timeStepKey),
                _buildStepLabel(
                  2,
                  isAr ? 'اختر وقت' : 'Choose a time',
                  hint: isAr
                      ? 'اختر وقتاً لرؤية المعلمين المتاحين'
                      : 'Pick a time to see available teachers',
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final t in times)
                      _buildTimeChip(
                        t,
                        selectedTime == t,
                        () {
                          final candidates = _slotsForCurrentLesson()
                              .where(
                                (s) =>
                                    s.dayKey == _dateKey(selectedDay!) &&
                                    s.time == t,
                              )
                              .toList();
                          final preferred = candidates.firstWhere(
                            (s) =>
                                _slotStatus(
                                  s,
                                  sessionNo: _flowLessonNo,
                                ).index <=
                                _SlotStatus.joinWithSessionChange.index,
                            orElse: () => candidates.first,
                          );
                          final preferredStatus = _slotStatus(
                            preferred,
                            sessionNo: _flowLessonNo,
                          );
                          if (preferredStatus == _SlotStatus.closed) {
                            _showClosedSlotInfo();
                            return;
                          }
                          if (preferredStatus == _SlotStatus.unavailable ||
                              preferredStatus == _SlotStatus.booked) {
                            _toast(_blockedSlotToast(preferred));
                            return;
                          }
                          setState(() {
                            selectedTime = t;
                            selectedTeacherId = null;
                          });
                          _scrollTo(_teacherStepKey);
                        },
                        status: () {
                          final candidates = _slotsForCurrentLesson().where(
                            (s) =>
                                s.dayKey == _dateKey(selectedDay!) &&
                                s.time == t,
                          );
                          _SlotStatus best = _SlotStatus.closed;
                          for (final c in candidates) {
                            final st = _slotStatus(c, sessionNo: _flowLessonNo);
                            if (st.index < best.index) best = st;
                          }
                          return candidates.isEmpty
                              ? _SlotStatus.availableBook
                              : best;
                        }(),
                        label: () {
                          final candidates = _slotsForCurrentLesson()
                              .where(
                                (s) =>
                                    s.dayKey == _dateKey(selectedDay!) &&
                                    s.time == t,
                              )
                              .toList();
                          if (candidates.isEmpty) return t;
                          final preferred = candidates.firstWhere(
                            (s) =>
                                _slotStatus(
                                  s,
                                  sessionNo: _flowLessonNo,
                                ).index <=
                                _SlotStatus.joinWithSessionChange.index,
                            orElse: () => candidates.first,
                          );
                          final kind = _chipMatchKindForSlot(
                            preferred,
                            targetSession: _flowLessonNo,
                          );
                          if (kind == _ChipMatchKind.none) {
                            return _timeChipLabel(
                              t,
                              _slotStatus(preferred, sessionNo: _flowLessonNo),
                              slot: preferred,
                            );
                          }
                          return _timeChipDetailsLabel(
                            preferred,
                            targetSession: _flowLessonNo,
                          );
                        }(),
                        pulse: () {
                          final candidates = _slotsForCurrentLesson()
                              .where(
                                (s) =>
                                    s.dayKey == _dateKey(selectedDay!) &&
                                    s.time == t,
                              )
                              .toList();
                          if (candidates.isEmpty) return false;
                          final preferred = candidates.firstWhere(
                            (s) =>
                                _slotStatus(
                                  s,
                                  sessionNo: _flowLessonNo,
                                ).index <=
                                _SlotStatus.joinWithSessionChange.index,
                            orElse: () => candidates.first,
                          );
                          return _chipMatchKindForSlot(
                                preferred,
                                targetSession: _flowLessonNo,
                              ) !=
                              _ChipMatchKind.none;
                        }(),
                        onDetailsTap: () {
                          final candidates = _slotsForCurrentLesson()
                              .where(
                                (s) =>
                                    s.dayKey == _dateKey(selectedDay!) &&
                                    s.time == t,
                              )
                              .toList();
                          if (candidates.isEmpty) return;
                          final preferred = candidates.firstWhere(
                            (s) =>
                                _slotStatus(
                                  s,
                                  sessionNo: _flowLessonNo,
                                ).index <=
                                _SlotStatus.joinWithSessionChange.index,
                            orElse: () => candidates.first,
                          );
                          _showSessionMiniDetails(preferred);
                        },
                      ),
                  ],
                ),
              ],
            ),
          ),
        if (selectedTime != null)
          _buildStepCard(
            isActive: true,
            isCompleted: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(key: _teacherStepKey),
                _buildStepLabel(
                  3,
                  isAr ? 'اختر معلم' : 'Choose a teacher',
                  hint: isAr
                      ? 'اختر معلمك لتأكيد الحجز'
                      : 'Select your teacher to confirm booking',
                ),
                const SizedBox(height: 6),
                ...teachers.map((s) {
                  final cap = s.maxLearnersPerSlot <= 0
                      ? 6
                      : s.maxLearnersPerSlot;
                  final booked = _effectiveBookedCount(s);
                  final left = (cap - booked) < 0 ? 0 : (cap - booked);
                  final status = _slotStatus(s, sessionNo: _flowLessonNo);
                  final canSelect =
                      status != _SlotStatus.unavailable &&
                      status != _SlotStatus.closed &&
                      status != _SlotStatus.booked;
                  final tint = _teacherTint(s.teacherId);
                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: tint,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: tint.withValues(alpha: 0.9)),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: InkWell(
                            borderRadius: BorderRadius.circular(10),
                            onTap: () => _openTeacherProfileSheet(s),
                            child: Row(
                              children: [
                                ProfileAvatar(
                                  name: s.teacherName,
                                  photoUrl: s.teacherPhotoUrl,
                                  radius: 19,
                                  borderColor: Colors.white.withValues(
                                    alpha: 0.9,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        s.teacherName,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w900,
                                          color: primaryBlue,
                                        ),
                                      ),
                                      const SizedBox(height: 3),
                                      Wrap(
                                        spacing: 8,
                                        runSpacing: 6,
                                        crossAxisAlignment:
                                            WrapCrossAlignment.center,
                                        children: [
                                          Text(
                                            status ==
                                                    _SlotStatus
                                                        .joinWithSessionChange
                                                ? '$left seats • Session ${_effectiveGroupSessionNo(s) ?? '-'}'
                                                : '$left seats available',
                                            style: TextStyle(
                                              fontWeight: FontWeight.w700,
                                              color: Colors.grey.shade700,
                                            ),
                                          ),
                                          if (s.hasIntroVideo)
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 6,
                                                    vertical: 2,
                                                  ),
                                              decoration: BoxDecoration(
                                                color: Colors.white.withValues(
                                                  alpha: 0.8,
                                                ),
                                                borderRadius:
                                                    BorderRadius.circular(999),
                                              ),
                                              child: const Text(
                                                'Video',
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w800,
                                                  color: primaryBlue,
                                                ),
                                              ),
                                            ),
                                          _slotStateBadge(status),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: actionOrange,
                          ),
                          onPressed: canSelect
                              ? () => setState(() {
                                  selectedTeacherId = s.teacherId;
                                  confirmSessionNo = _flowLessonNo;
                                  flowStep = _BookingFlowStep.confirm;
                                })
                              : null,
                          child: Text(
                            canSelect
                                ? (isAr ? 'اختيار' : 'Select')
                                : (isAr ? 'مقفول' : 'Locked'),
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
    );
  }

  Widget _buildPathCard({
    required _SchedulePath path,
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    final selected = schedulePath == path;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () {
        if (schedulePath == path) return;
        setState(() {
          schedulePath = path;
          _resetScheduleSelections();
        });
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selected ? primaryBlue : Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? primaryBlue : uiBorder,
            width: selected ? 1.5 : 1,
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: primaryBlue.withValues(alpha: 0.25),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ]
              : [],
        ),
        child: Column(
          children: [
            Icon(icon, color: selected ? Colors.white : primaryBlue, size: 24),
            const SizedBox(height: 8),
            Text(
              title,
              style: TextStyle(
                fontWeight: FontWeight.w900,
                color: selected ? Colors.white : primaryBlue,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: selected
                    ? Colors.white.withValues(alpha: 0.8)
                    : Colors.grey.shade600,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildScheduleStep() {
    final isAr = lessonChoiceArabic;
    final recommended = _recommendedMatchSlots();
    return Directionality(
      textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildScheduleHeader(),
          if (recommended.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFF2FAFF),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFFBEE6FA)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _recommendedTitle(helpLang),
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      color: primaryBlue,
                    ),
                  ),
                  const SizedBox(height: 8),
                  ...recommended.map((s) {
                    final kind = _chipMatchKindForSlot(
                      s,
                      targetSession: _flowLessonNo,
                    );
                    final isApplied = _appliedRecommendationKey == s.key;
                    final pulseScale = kind == _ChipMatchKind.exact
                        ? 1 + (_sessionPulseCtrl.value * 0.024)
                        : 1 + (_sessionPulseCtrl.value * 0.016);
                    final actionLabel =
                        kind == _ChipMatchKind.matchDifferentSession
                        ? 'Join group'
                        : 'Confirm book';
                    return AnimatedBuilder(
                      animation: _sessionPulseCtrl,
                      builder: (_, child) =>
                          Transform.scale(scale: pulseScale, child: child),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => _applyRecommendedSlot(s),
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: kind == _ChipMatchKind.exact
                                  ? const [Color(0xFFD5F1E0), Color(0xFFBEE8CF)]
                                  : const [
                                      Color(0xFFD9EFFF),
                                      Color(0xFFBFE2FF),
                                    ],
                            ),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: kind == _ChipMatchKind.exact
                                  ? exactMatchBorder
                                  : switchSessionBorder,
                              width: isApplied ? 2.4 : 1.8,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color:
                                    (kind == _ChipMatchKind.exact
                                            ? exactMatchBorder
                                            : switchSessionBorder)
                                        .withValues(alpha: 0.22),
                                blurRadius: isApplied ? 14 : 10,
                                offset: const Offset(0, 5),
                              ),
                            ],
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      s.teacherName,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w900,
                                        color: primaryBlue,
                                        fontSize: 14,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      _timeChipDetailsLabel(s),
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w800,
                                        color: primaryBlue,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              FilledButton(
                                style: FilledButton.styleFrom(
                                  backgroundColor: kind == _ChipMatchKind.exact
                                      ? const Color(0xFF1F8A49)
                                      : primaryBlue,
                                  foregroundColor: Colors.white,
                                  minimumSize: const Size(0, 34),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                  ),
                                  visualDensity: VisualDensity.compact,
                                ),
                                onPressed: () {
                                  setState(() {
                                    _appliedRecommendationKey = s.key;
                                    schedulePath = _SchedulePath.byTeacher;
                                    _teachersCollapsed = true;
                                    selectedTeacherFirstId = s.teacherId;
                                    selectedTeacherId = s.teacherId;
                                    selectedDay = DateTime(
                                      s.start.year,
                                      s.start.month,
                                      s.start.day,
                                    );
                                    selectedTime = s.time;
                                    confirmSessionNo =
                                        kind ==
                                            _ChipMatchKind.matchDifferentSession
                                        ? (_effectiveGroupSessionNo(s) ??
                                              _flowLessonNo)
                                        : _flowLessonNo;
                                    flowStep = _BookingFlowStep.confirm;
                                  });
                                },
                                child: Text(actionLabel),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }),
                ],
              ),
            ),
          ],
          const SizedBox(height: 16),
          Text(
            isAr ? 'كيف تريد البحث؟' : 'How would you like to search?',
            style: TextStyle(
              fontWeight: FontWeight.w900,
              color: palette.text.withValues(alpha: 0.7),
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _buildPathCard(
                  path: _SchedulePath.byTeacher,
                  icon: Icons.person_search_rounded,
                  title: isAr ? 'حسب المعلم' : 'By Teacher',
                  subtitle: isAr
                      ? 'اختر معلمك المفضل أولاً'
                      : 'Find your preferred teacher first',
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildPathCard(
                  path: _SchedulePath.byDay,
                  icon: Icons.calendar_month_rounded,
                  title: isAr ? 'حسب التوقيت' : 'By Day',
                  subtitle: isAr ? 'اختر التاريخ أولاً' : 'Pick a date first',
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            child: schedulePath == _SchedulePath.byTeacher
                ? KeyedSubtree(
                    key: const ValueKey('by_teacher'),
                    child: _buildByTeacherPath(),
                  )
                : KeyedSubtree(
                    key: const ValueKey('by_day'),
                    child: _buildByDayPath(),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildConfirmStep() {
    final sessionNo = confirmSessionNo ?? _flowLessonNo;
    final limitReached = upcomingBookingsCount >= 3;
    final teachers = _teachersForDayAndTime();
    final chosen = teachers
        .where((e) => e.teacherId == selectedTeacherId)
        .toList();
    final slot = chosen.isEmpty ? null : chosen.first;
    final isAr = lessonChoiceArabic;
    if (slot == null ||
        selectedDay == null ||
        selectedTime == null ||
        sessionNo <= 0) {
      return Text(
        isAr
            ? 'انتهت صلاحية الاختيار. اختر مرة أخرى.'
            : 'Selection expired. Please choose again.',
      );
    }
    final cap = slot.maxLearnersPerSlot <= 0 ? 6 : slot.maxLearnersPerSlot;
    final booked = _effectiveBookedCount(slot);
    final left = (cap - booked) < 0 ? 0 : (cap - booked);
    final sessionTitle = _sessionTitleFor(sessionNo);

    return Directionality(
      textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isAr ? 'تأكيد الحجز' : 'Confirm your booking',
            style: const TextStyle(
              fontWeight: FontWeight.w900,
              color: primaryBlue,
              fontSize: 24,
            ),
          ),
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              gradient: const LinearGradient(
                colors: [Color(0xFF0E7C86), Color(0xFF0A5E66)],
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF0E7C86).withValues(alpha: 0.3),
                  blurRadius: 14,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
                  children: [
                    Expanded(
                      child: Text(
                        courseTitle,
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          color: Colors.white,
                          fontSize: 16,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white38),
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      onPressed: () =>
                          setState(() => flowStep = _BookingFlowStep.schedule),
                      child: Text(
                        isAr ? 'تغيير الحصة' : 'Change session',
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Divider(color: Colors.white.withValues(alpha: 0.15), height: 1),
                const SizedBox(height: 14),
                _buildSessionLinePill(
                  label: _sessionLabel(sessionNo),
                  onPrimary: true,
                  compact: true,
                ),
                if (sessionTitle.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    sessionTitle,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      fontSize: 15,
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                Divider(color: Colors.white.withValues(alpha: 0.15), height: 1),
                const SizedBox(height: 14),
                InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => _openTeacherProfileSheet(slot),
                  child: Row(
                    textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
                    children: [
                      ProfileAvatar(
                        name: slot.teacherName,
                        photoUrl: slot.teacherPhotoUrl,
                        radius: 20,
                        borderColor: Colors.white.withValues(alpha: 0.6),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          slot.teacherName,
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                            fontSize: 15,
                          ),
                        ),
                      ),
                      if (slot.hasIntroVideo)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: const Text(
                            'Video',
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 11,
                              color: Colors.white,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '${_friendlyDate(selectedDay!)} • $selectedTime',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: Colors.white.withValues(alpha: 0.85),
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 14),
                Divider(color: Colors.white.withValues(alpha: 0.15), height: 1),
                const SizedBox(height: 14),
                Text(
                  _confirmObjectiveLabel(),
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: Colors.white.withValues(alpha: 0.8),
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _sessionObjectiveFor(sessionNo).isEmpty
                      ? _cancelNoObjectiveLabel()
                      : _sessionObjectiveFor(sessionNo),
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.9),
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 14),
                Divider(color: Colors.white.withValues(alpha: 0.15), height: 1),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Icon(
                      Icons.people_rounded,
                      size: 16,
                      color: Colors.white.withValues(alpha: 0.7),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      isAr
                          ? 'المقاعد المتبقية: $left'
                          : 'Spots remaining: $left',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: Colors.white.withValues(alpha: 0.85),
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Row(
            textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFB91C1C),
                    side: const BorderSide(color: Color(0xFFB91C1C)),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: () =>
                      setState(() => flowStep = _BookingFlowStep.schedule),
                  icon: const Icon(Icons.arrow_back_rounded, size: 18),
                  label: Text(
                    isAr ? 'رجوع' : 'Back',
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                flex: 2,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: actionOrange,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 16,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: limitReached
                      ? null
                      : () async {
                          await _bookSlot(slot, sessionNo: sessionNo);
                          if (!mounted) return;
                          if (myBookedSlots.containsKey(slot.key)) {
                            setState(() => flowStep = _BookingFlowStep.success);
                          }
                        },
                  icon: const Icon(Icons.check_circle_rounded, size: 20),
                  label: Text(
                    isAr ? 'تأكيد الحجز' : 'Confirm booking',
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 15,
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (limitReached) ...[
            const SizedBox(height: 12),
            Text(
              _bookingLimitNote(),
              style: const TextStyle(
                color: Color(0xFF8A3D27),
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSuccessStep() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: uiBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Your class has been booked.',
            style: TextStyle(
              fontWeight: FontWeight.w900,
              color: primaryBlue,
              fontSize: 22,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: actionOrange),
                onPressed: _onBookAnother,
                child: const Text('Book another class'),
              ),
              OutlinedButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Done'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFlowContent() {
    switch (flowStep) {
      case _BookingFlowStep.lessonChoice:
        return _buildLessonChoiceStep();
      case _BookingFlowStep.schedule:
        return _buildScheduleStep();
      case _BookingFlowStep.confirm:
        return _buildConfirmStep();
      case _BookingFlowStep.success:
        return _buildSuccessStep();
    }
  }

  @override
  Widget build(BuildContext context) {
    final cid = courseId;
    final busy = loading || booking || refreshing || progressLabel.isNotEmpty;

    return PopScope(
      canPop: _isAtEntryStep(),
      onPopInvokedWithResult: (didPop, __) {
        if (didPop) return;
        final handled = _goBackOneStepInFlow();
        if (!handled) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        backgroundColor: palette.appBg,
        appBar: AppBar(
          backgroundColor: palette.cardBg,
          elevation: 0,
          surfaceTintColor: palette.cardBg,
          iconTheme: IconThemeData(color: palette.primary),
          leading: IconButton(
            icon: Icon(Icons.arrow_back_rounded, color: palette.primary),
            onPressed: () {
              final handled = _goBackOneStepInFlow();
              if (!handled) {
                Navigator.of(context).pop();
              }
            },
          ),
          title: Directionality(
            textDirection: lessonChoiceArabic
                ? TextDirection.rtl
                : TextDirection.ltr,
            child: Text(
              _bookingScreenTitle(),
              style: TextStyle(
                color: palette.primary,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          actions: [
            IconButton(
              tooltip: lessonChoiceArabic ? 'English' : 'العربية',
              onPressed: () =>
                  setState(() => lessonChoiceArabic = !lessonChoiceArabic),
              icon: Icon(Icons.translate_rounded, color: palette.primary),
            ),
            IconButton(
              tooltip: 'How booking works',
              onPressed: _openHowBookingWorks,
              icon: Icon(Icons.help_outline_rounded, color: palette.primary),
            ),
            const SizedBox.shrink(),
            IconButton(
              tooltip: 'Refresh',
              onPressed: (loading || booking || refreshing || cid == null)
                  ? null
                  : () async {
                      await _runBusy('Refreshing schedule...', () async {
                        await _refreshSchedule();
                      });
                    },
              icon: Icon(Icons.refresh_rounded, color: palette.primary),
            ),
            const SizedBox(width: 4),
          ],
        ),
        body: WatermarkBackground(
          child: learnerWebBodyFrame(
            context: context,
            maxWidth: 1500,
            child: Stack(
              children: [
                IgnorePointer(
                  ignoring: busy,
                  child: loading
                      ? const Center(
                          child: BrandedInlineLoader(
                            message: 'Loading booking schedule...',
                          ),
                        )
                      : (cid == null)
                      ? const Center(child: Text('No course selected.'))
                      : Align(
                          alignment: Alignment.topCenter,
                          child: SingleChildScrollView(
                            controller: _pageScrollCtrl,
                            padding: const EdgeInsets.fromLTRB(0, 8, 0, 88),
                            child: Column(
                              children: [
                                const SizedBox(height: 10),
                                AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 300),
                                  switchInCurve: Curves.easeOut,
                                  switchOutCurve: Curves.easeIn,
                                  transitionBuilder:
                                      (
                                        Widget child,
                                        Animation<double> animation,
                                      ) {
                                        return SlideTransition(
                                          position: Tween<Offset>(
                                            begin: const Offset(0.06, 0),
                                            end: Offset.zero,
                                          ).animate(animation),
                                          child: FadeTransition(
                                            opacity: animation,
                                            child: child,
                                          ),
                                        );
                                      },
                                  child: KeyedSubtree(
                                    key: ValueKey(flowStep),
                                    child: _buildFlowShell(_buildFlowContent()),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                ),
                if (busy)
                  Positioned.fill(
                    child: Container(
                      color: Colors.black.withValues(alpha: 0.16),
                      child: Center(
                        child: Container(
                          width: 220,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 18,
                            vertical: 18,
                          ),
                          decoration: BoxDecoration(
                            color: palette.cardBg,
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(color: palette.border),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const YbsBusyLogo(size: 44),
                              const SizedBox(height: 14),
                              Text(
                                progressLabel.isEmpty
                                    ? 'Please wait...'
                                    : progressLabel,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontWeight: FontWeight.w900,
                                  color: palette.primary,
                                ),
                              ),
                              const SizedBox(height: 8),
                              StreamBuilder<int>(
                                stream: Stream.periodic(
                                  const Duration(seconds: 1),
                                  (x) => x,
                                ),
                                initialData: 0,
                                builder: (context, _) {
                                  final since = _busyVisualSince;
                                  if (since == null) {
                                    return const SizedBox.shrink();
                                  }
                                  final elapsed = DateTime.now().difference(
                                    since,
                                  );
                                  if (elapsed <
                                      const Duration(milliseconds: 2500)) {
                                    return const SizedBox.shrink();
                                  }
                                  final sec = elapsed.inSeconds;
                                  return Text(
                                    'Still working... ${sec}s',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                      color: palette.text.withValues(
                                        alpha: 0.72,
                                      ),
                                      fontSize: 12,
                                    ),
                                  );
                                },
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _sessionTitleFor(int sessionNo) {
    final info = curriculumSessions['$sessionNo'];
    if (info is Map) {
      final m = info.map((k, v) => MapEntry(k.toString(), v));
      final t = (m['sessionTitle'] ?? m['title'] ?? '').toString().trim();
      if (t.isNotEmpty) return t;
    }
    return '';
  }

  String _sessionObjectiveFor(int sessionNo) {
    final info = curriculumSessions['$sessionNo'];
    if (info is Map) {
      final m = info.map((k, v) => MapEntry(k.toString(), v));
      final objective = (m['objective'] ?? m['goal'] ?? '').toString().trim();
      if (objective.isNotEmpty) return objective;
    }
    return '';
  }

  String _friendlyDate(DateTime d) {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final wd = days[d.weekday - 1];
    final mo = months[d.month - 1];
    return '$wd, ${_two(d.day)} $mo';
  }
}

// ================== Models ==================

enum _CancelBookingStatus { cancelled, notFound, locked, failed }

enum _BookingFlowStep { lessonChoice, schedule, confirm, success }

enum _SchedulePath { byTeacher, byDay }

enum _ChipMatchKind { none, matchDifferentSession, exact }

enum _DaySlotSummary { none, groupOnly, available }

class _CourseChoice {
  final String id;
  final String title;
  final String courseCode;
  final String thumbnailUrl;

  const _CourseChoice({
    required this.id,
    required this.title,
    this.courseCode = '',
    this.thumbnailUrl = '',
  });
}

class _BookingGate {
  final bool enabled;
  final int totalSessions;
  final String title;
  final String source;

  const _BookingGate({
    required this.enabled,
    required this.totalSessions,
    required this.title,
    required this.source,
  });
}

class _TeacherAvail {
  final String teacherId;
  final String teacherName;
  final Map<String, List<String>> slotsByDay;
  final String meetUrl;
  final String teacherPhotoUrl;
  final bool hasIntroVideo;
  final int durationMinutes;
  final int maxLearnersPerSlot;

  _TeacherAvail({
    required this.teacherId,
    required this.teacherName,
    required this.slotsByDay,
    required this.meetUrl,
    required this.teacherPhotoUrl,
    required this.hasIntroVideo,
    required this.durationMinutes,
    required this.maxLearnersPerSlot,
  });
}

class _SlotSummary {
  final int bookedCount;
  final int? groupSessionNo;
  final bool bookedByMe;

  _SlotSummary({
    required this.bookedCount,
    required this.groupSessionNo,
    required this.bookedByMe,
  });
}

class _Slot {
  final String courseId;
  final String dayKey;
  final String time;
  final DateTime start;
  final String teacherId;
  final String teacherName;
  final String meetUrl;
  final String teacherPhotoUrl;
  final bool hasIntroVideo;
  final int durationMinutes;
  final int maxLearnersPerSlot;
  final bool bookedByMe;
  final int bookedCount;
  final int? groupSessionNo;

  _Slot({
    required this.courseId,
    required this.dayKey,
    required this.time,
    required this.start,
    required this.teacherId,
    required this.teacherName,
    required this.meetUrl,
    required this.teacherPhotoUrl,
    required this.hasIntroVideo,
    required this.durationMinutes,
    required this.maxLearnersPerSlot,
    this.bookedByMe = false,
    this.bookedCount = 0,
    this.groupSessionNo,
  });

  String get key => '$dayKey|$time|$teacherId';

  bool get isFull {
    final cap = maxLearnersPerSlot <= 0 ? 6 : maxLearnersPerSlot;
    return bookedCount >= cap;
  }
}

enum _SlotStatus {
  availableBook,
  joinSameSession,
  joinWithSessionChange,
  booked,
  unavailable,
  closed,
}

class _GlobalSlotOccupancy {
  final String courseId;
  final int? sessionNo;
  final int learnerCount;
  final bool bookedByMe;

  const _GlobalSlotOccupancy({
    required this.courseId,
    required this.sessionNo,
    required this.learnerCount,
    required this.bookedByMe,
  });
}

class _TeacherMiniProfile {
  final String name;
  final String photoUrl;
  final bool hasIntroVideo;

  const _TeacherMiniProfile({
    required this.name,
    required this.photoUrl,
    required this.hasIntroVideo,
  });
}

class _TeacherFullProfile {
  final String aboutMe;
  final String introVideoUrl;
  final bool socialVisible;
  final Map<String, String> socialLinks;

  const _TeacherFullProfile({
    this.aboutMe = '',
    this.introVideoUrl = '',
    this.socialVisible = true,
    this.socialLinks = const <String, String>{},
  });
}

class _BusyRange {
  final DateTime start;
  final DateTime end;

  const _BusyRange({required this.start, required this.end});
}

class _MyBooking {
  final String dayKey;
  final String time;
  final DateTime start;
  final String teacherId;
  final String teacherName;
  final int sessionNo;

  _MyBooking({
    required this.dayKey,
    required this.time,
    required this.start,
    required this.teacherId,
    required this.teacherName,
    required this.sessionNo,
  });
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
