import 'dart:async';

import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'teacher_public_gallery_screen.dart';
import 'teacher_online_circle_screen.dart';
import '../shared/app_feedback.dart';
import '../shared/app_theme.dart';
import '../shared/first_login_agreement.dart';
import '../shared/offline_action_guard.dart';
import '../shared/offline_notice_banner.dart';
import '../shared/responsive_layout.dart';
import '../shared/icon_theme.dart';
import '../shared/session_manager.dart';
import '../shared/teacher_web_layout.dart';
import 'teacher_stories_screen.dart';
import 'teacher_classes.dart';
import 'teacher_games_screen.dart';
import 'teacher_mail.dart';
import 'teacher_online_booking.dart';
import 'teacher_homework_inbox_screen.dart';
import 'teacher_profile.dart';
import 'teacher_regulations_screen.dart';
import 'teacher_reminder.dart';
import 'teacher_schedule.dart';
import 'teacher_class_progress_screen.dart';
import 'teacher_shared_files_screen.dart';
import 'teacher_syllabi_screen.dart';
import 'teacher_wages_screen.dart';
import 'teacher_my_platform_screen.dart';
import 'take_attendance_screen.dart';
import 'teacher_schedule_data_service.dart';
import '../services/notification_service.dart';
import '../services/notification_counter_service.dart';
import '../services/teacher_schedule_widget_service.dart';
import '../services/window_access_service.dart';

class TeacherHomeScreen extends StatefulWidget {
  const TeacherHomeScreen({super.key});

  @override
  State<TeacherHomeScreen> createState() => _TeacherHomeScreenState();
}

class _TeacherHomeScreenState extends State<TeacherHomeScreen> {
  static const String usersNode = 'users';
  static const String classesNode = 'classes';
  static const String _attendanceReminderKeysPref =
      'teacher_home_attendance_reminder_keys_v1';
  int _lastBackPressMs = 0;

  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final GlobalKey _menuButtonKey = GlobalKey();
  final GlobalKey _heroCardKey = GlobalKey();
  final GlobalKey _inboxCardKey = GlobalKey();
  final GlobalKey _homeworkCardKey = GlobalKey();
  final GlobalKey _remindersCardKey = GlobalKey();
  final GlobalKey _overviewPanelKey = GlobalKey();
  final GlobalKey _nextClassCardKey = GlobalKey();

  Stream<DatabaseEvent>? _remindersStream;
  Stream<DatabaseEvent>? _mailIndexStream;

  Future<_ClassesSummary>? _classesSummaryFuture;
  Future<int>? _upcomingOnlineCountFuture;
  Future<String>? _displayNameFuture;
  Future<List<_HomeUpcomingClass>>? _nextUpcomingClassesFuture;
  Timer? _attendanceReminderTimer;
  bool _attendanceReminderCheckInProgress = false;
  bool _attendanceReminderSyncInProgress = false;
  bool _attendanceReminderDialogOpen = false;
  final Set<String> _handledAttendanceReminderKeys = <String>{};

  @override
  void initState() {
    super.initState();
    appThemeController.addListener(_onThemeChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      FirstLoginAgreement.ensureAccepted(context, roleKey: 'teacher');
    });

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      _remindersStream = _db
          .child('reminders/$uid')
          .onValue
          .asBroadcastStream();
      _mailIndexStream = _db
          .child('mail_index/$uid')
          .onValue
          .asBroadcastStream();
      _classesSummaryFuture = _loadClassesSummaryForHome(uid);
      _upcomingOnlineCountFuture = _loadUpcomingOnlineCountForHome(uid);
      _displayNameFuture = _myDisplayName();
      _nextUpcomingClassesFuture = _loadNextUpcomingClassesForHome(uid);
      _startAttendanceReminderWatcher(uid);
    }
  }

  @override
  void dispose() {
    _attendanceReminderTimer?.cancel();
    appThemeController.removeListener(_onThemeChanged);
    super.dispose();
  }

  _HomePalette get palette => _toHomePalette(appThemeController.palette);

  void _startAttendanceReminderWatcher(String uid) {
    _attendanceReminderTimer?.cancel();
    unawaited(NotificationService.I.init());
    unawaited(NotificationService.I.requestPermissions());
    Future<void>.delayed(const Duration(seconds: 2), () async {
      if (!mounted) return;
      await _pollAttendanceReminder(uid);
    });
    _attendanceReminderTimer = Timer.periodic(const Duration(minutes: 1), (
      _,
    ) async {
      await _pollAttendanceReminder(uid);
    });
  }

  Future<void> _pollAttendanceReminder(String uid) async {
    if (!mounted ||
        _attendanceReminderCheckInProgress ||
        _attendanceReminderDialogOpen) {
      return;
    }
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return;

    _attendanceReminderCheckInProgress = true;
    try {
      await _syncAttendanceReminderNotifications(uid);
      final pending = await _loadPendingAttendanceReminderForHome(uid);
      if (!mounted || pending == null) return;
      if (_handledAttendanceReminderKeys.contains(pending.reminderKey)) return;
      await _showAttendanceReminderDialog(pending);
    } finally {
      _attendanceReminderCheckInProgress = false;
    }
  }

  Future<void> _syncAttendanceReminderNotifications(String teacherUid) async {
    if (_attendanceReminderSyncInProgress) return;
    _attendanceReminderSyncInProgress = true;
    try {
      final identity = await _loadTeacherIdentityForHome(teacherUid);
      final snap = await _db.child(classesNode).get();
      final prefs = await SharedPreferences.getInstance();
      final prevKeys =
          prefs.getStringList(_attendanceReminderKeysPref) ?? const [];

      if (!snap.exists || snap.value == null || snap.value is! Map) {
        for (final key in prevKeys) {
          final parsed = _parseAttendanceReminderKey(key);
          if (parsed == null) continue;
          await NotificationService.I.cancelAttendanceReminder(
            classId: parsed.classId,
            sessionStart: parsed.start,
          );
        }
        await prefs.setStringList(_attendanceReminderKeysPref, const []);
        return;
      }

      final raw = Map<dynamic, dynamic>.from(snap.value as Map);
      final now = DateTime.now();
      final candidates = <_HomeUpcomingClass>[];

      for (final entry in raw.entries) {
        final value = entry.value;
        if (value is! Map) continue;

        final classMap = Map<String, dynamic>.from(value);
        if (!_matchesTeacherForHome(
          classMap,
          teacherUid: teacherUid,
          teacherName: identity.name,
          teacherSerial: identity.serial,
        )) {
          continue;
        }

        for (final occ in _generateOccurrencesForHome(classMap)) {
          if (occ.isOnline || !occ.end.isAfter(now)) continue;
          candidates.add(occ);
        }
      }

      candidates.sort((a, b) => a.end.compareTo(b.end));
      final trimmed = candidates.take(30).toList();
      final nextKeys = <String>{
        for (final occ in trimmed) _attendanceReminderKey(occ),
      };

      for (final key in prevKeys) {
        if (nextKeys.contains(key)) continue;
        final parsed = _parseAttendanceReminderKey(key);
        if (parsed == null) continue;
        await NotificationService.I.cancelAttendanceReminder(
          classId: parsed.classId,
          sessionStart: parsed.start,
        );
      }

      for (final occ in trimmed) {
        await NotificationService.I.scheduleAttendanceReminder(
          classId: occ.classId,
          title: 'Attendance Needed',
          body:
              '${occ.courseCode.isEmpty ? 'Class' : occ.courseCode} just ended. Please take attendance now.',
          sessionStart: occ.start,
          remindAt: occ.end,
        );
      }

      await prefs.setStringList(_attendanceReminderKeysPref, nextKeys.toList());
    } catch (_) {
      // Keep the home screen usable even if reminder sync fails.
    } finally {
      _attendanceReminderSyncInProgress = false;
    }
  }

  String _attendanceReminderKey(_HomeUpcomingClass occ) {
    return '${occ.classId}@@${occ.start.toIso8601String()}';
  }

  ({String classId, DateTime start})? _parseAttendanceReminderKey(String raw) {
    final i = raw.lastIndexOf('@@');
    if (i <= 0) return null;
    final classId = raw.substring(0, i);
    final dt = DateTime.tryParse(raw.substring(i + 2));
    if (classId.isEmpty || dt == null) return null;
    return (classId: classId, start: dt);
  }

  Future<_HomeAttendanceReminder?> _loadPendingAttendanceReminderForHome(
    String teacherUid,
  ) async {
    try {
      final identity = await _loadTeacherIdentityForHome(teacherUid);
      final snap = await _db.child(classesNode).get();
      if (!snap.exists || snap.value == null || snap.value is! Map) {
        return null;
      }

      final raw = Map<dynamic, dynamic>.from(snap.value as Map);
      final now = DateTime.now();
      final cutoff = now.subtract(const Duration(hours: 12));
      final pending = <_HomeAttendanceReminder>[];

      for (final entry in raw.entries) {
        final value = entry.value;
        if (value is! Map) continue;

        final classMap = Map<String, dynamic>.from(value);
        if (!_matchesTeacherForHome(
          classMap,
          teacherUid: teacherUid,
          teacherName: identity.name,
          teacherSerial: identity.serial,
        )) {
          continue;
        }

        final occurrences = _generateOccurrencesForHome(classMap);
        for (final occ in occurrences) {
          if (occ.isOnline) continue;
          if (occ.end.isAfter(now) || occ.end.isBefore(cutoff)) continue;
          if (_hasAttendanceForDate(classMap, occ.start)) continue;
          pending.add(
            _HomeAttendanceReminder(classData: classMap, occurrence: occ),
          );
        }
      }

      if (pending.isEmpty) return null;
      pending.sort((a, b) => a.occurrence.end.compareTo(b.occurrence.end));
      return pending.first;
    } catch (_) {
      return null;
    }
  }

  bool _hasAttendanceForDate(Map<String, dynamic> classData, DateTime date) {
    final attendanceRaw = classData['attendance'];
    if (attendanceRaw is! Map) return false;
    final dateKey = DateFormat('yyyy-MM-dd').format(date);
    final attendanceMap = Map<dynamic, dynamic>.from(attendanceRaw);
    for (final value in attendanceMap.values) {
      if (value is! Map) continue;
      final record = value.map((k, v) => MapEntry(k.toString(), v));
      final recordDate = (record['date'] ?? '').toString().trim();
      if (recordDate == dateKey) return true;
    }
    return false;
  }

  Future<void> _showAttendanceReminderDialog(
    _HomeAttendanceReminder reminder,
  ) async {
    if (!mounted) return;

    final p = palette;
    _attendanceReminderDialogOpen = true;
    _handledAttendanceReminderKeys.add(reminder.reminderKey);

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: p.cardBg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: Text(
            'Attendance Needed',
            style: TextStyle(color: p.primary, fontWeight: FontWeight.w900),
          ),
          content: Text(
            '${reminder.displayTitle} ended at ${DateFormat('h:mm a').format(reminder.occurrence.end)}. Please take attendance now.',
            style: TextStyle(color: p.text, fontWeight: FontWeight.w600),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(
                'Later',
                style: TextStyle(color: p.primary, fontWeight: FontWeight.w800),
              ),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: p.accent,
                foregroundColor: Colors.white,
              ),
              onPressed: () async {
                Navigator.of(dialogContext).pop();
                if (!mounted) return;
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => TakeAttendanceScreen(
                      classData: reminder.classData,
                      initialDate: reminder.occurrence.start,
                    ),
                  ),
                );
              },
              child: const Text('Take Attendance'),
            ),
          ],
        );
      },
    );

    _attendanceReminderDialogOpen = false;
  }

  Future<void> _refreshHome() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    setState(() {
      _displayNameFuture = _myDisplayName();
      _classesSummaryFuture = _loadClassesSummaryForHome(uid);
      _upcomingOnlineCountFuture = _loadUpcomingOnlineCountForHome(uid);
      _nextUpcomingClassesFuture = _loadNextUpcomingClassesForHome(uid);
    });

    await Future<void>.delayed(const Duration(milliseconds: 250));
  }

  Future<Map<String, dynamic>?> _classDataForUpcoming(String classId) async {
    final id = classId.trim();
    if (id.isEmpty) return null;

    try {
      final byKey = await _db.child('$classesNode/$id').get();
      if (byKey.exists && byKey.value is Map) {
        final m = Map<String, dynamic>.from(byKey.value as Map);
        if ((m['class_id'] ?? m['id'] ?? '').toString().trim().isEmpty) {
          m['class_id'] = id;
        }
        return m;
      }

      final all = await _db.child(classesNode).get();
      if (all.exists && all.value is Map) {
        final raw = Map<dynamic, dynamic>.from(all.value as Map);
        for (final e in raw.entries) {
          if (e.value is! Map) continue;
          final m = Map<String, dynamic>.from(e.value as Map);
          final cid = (m['class_id'] ?? m['id'] ?? '').toString().trim();
          if (cid == id) return m;
        }
      }
    } catch (_) {}

    return null;
  }

  Future<void> _openUpcomingTake(_HomeUpcomingClass occ) async {
    if (occ.isOnline) {
      _openTeacherWindow(
        AppWindowKeys.teacherOnlineAvailability,
        () => _pushScreen(
          const TeacherClassesScreen(initialMainTab: 1, initialOnlineTab: 2),
        ),
      );
      return;
    }

    final classData = await _classDataForUpcoming(occ.classId);
    if (!mounted || classData == null) return;

    _openTeacherWindow(
      AppWindowKeys.teacherClasses,
      () => _pushScreen(
        TakeAttendanceScreen(classData: classData, initialDate: occ.start),
      ),
    );
  }

  Future<void> _openUpcomingProgress(_HomeUpcomingClass occ) async {
    if (occ.isOnline) {
      _openTeacherWindow(
        AppWindowKeys.teacherOnlineAvailability,
        () => _pushScreen(
          const TeacherClassesScreen(initialMainTab: 1, initialOnlineTab: 2),
        ),
      );
      return;
    }

    final classData = await _classDataForUpcoming(occ.classId);
    if (!mounted || classData == null) return;

    _openTeacherWindow(
      AppWindowKeys.teacherClasses,
      () => _pushScreen(
        TeacherClassProgressScreen(classId: occ.classId, classData: classData),
      ),
    );
  }

  Future<void> _logout(BuildContext context) async {
    final userId = FirebaseAuth.instance.currentUser?.uid;

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

      if (userId != null && userId.isNotEmpty) {
        try {
          await FirebaseDatabase.instance.ref('fcm_tokens/$userId').remove();
        } catch (_) {}
      }

      try {
        await appThemeController.resetToDefault();
      } catch (_) {}
    }());
  }

  String _norm(String s) => s.trim().toLowerCase();

  bool _isTeacherRole(dynamic role) {
    final r = (role ?? '').toString().trim().toLowerCase();
    return r == 'teacher' || r == 'teachers' || r == 'teacher(s)';
  }

  int _learnersCount(Map<String, dynamic> classData) {
    final learners = classData['learners'];
    if (learners is Map) return learners.length;
    return 0;
  }

  Future<_ClassesSummary> _loadClassesSummaryForHome(String teacherUid) async {
    try {
      final usersRef = _db.child(usersNode);
      final classesRef = _db.child(classesNode);

      final userSnap = await usersRef.child(teacherUid).get();
      if (!userSnap.exists) {
        return const _ClassesSummary(classesCount: 0, learnersCount: 0);
      }

      final u = (userSnap.value is Map)
          ? Map<String, dynamic>.from(userSnap.value as Map)
          : <String, dynamic>{};

      if (!_isTeacherRole(u['role'])) {
        return const _ClassesSummary(classesCount: 0, learnersCount: 0);
      }

      final teacherSerial = (u['serial'] ?? '').toString().trim();
      final fn = (u['first_name'] ?? '').toString().trim();
      final ln = (u['last_name'] ?? '').toString().trim();
      final teacherName = ('$fn $ln').trim();

      final classesSnap = await classesRef.get();
      if (!classesSnap.exists || classesSnap.value == null) {
        return const _ClassesSummary(classesCount: 0, learnersCount: 0);
      }

      final raw = (classesSnap.value is Map)
          ? Map<dynamic, dynamic>.from(classesSnap.value as Map)
          : <dynamic, dynamic>{};

      int classesCount = 0;
      int learnersTotal = 0;

      raw.forEach((key, value) {
        final c = (value is Map)
            ? Map<String, dynamic>.from(value)
            : <String, dynamic>{};

        String curUid = '';
        String curName = '';
        String curSerial = '';

        final cur = c['instructor_current'];
        if (cur is Map) {
          final curMap = Map<String, dynamic>.from(cur);
          curUid = (curMap['uid'] ?? '').toString().trim();
          curName = (curMap['name'] ?? '').toString().trim();
          curSerial = (curMap['serial'] ?? '').toString().trim();
        }

        final legacyInstructorName = (c['instructor'] ?? '').toString().trim();

        final matchesUid = curUid.isNotEmpty && curUid == teacherUid;

        final matchesName =
            teacherName.isNotEmpty &&
            _norm(
                  legacyInstructorName.isNotEmpty
                      ? legacyInstructorName
                      : curName,
                ) ==
                _norm(teacherName);

        final legacySerial = (c['instructorserial'] ?? c['serial'] ?? curSerial)
            .toString()
            .trim();
        final matchesSerial =
            teacherSerial.isNotEmpty && legacySerial == teacherSerial;

        if (matchesUid || matchesName || matchesSerial) {
          classesCount += 1;
          learnersTotal += _learnersCount(c);
        }
      });

      return _ClassesSummary(
        classesCount: classesCount,
        learnersCount: learnersTotal,
      );
    } catch (_) {
      return const _ClassesSummary(classesCount: 0, learnersCount: 0);
    }
  }

  DateTime? _parseBookingSlotStart(String dayKey, String hhmm) {
    return TeacherScheduleDataService.parseBookingSlotStart(dayKey, hhmm);
  }

  Future<int> _loadUpcomingOnlineCountForHome(String teacherUid) async {
    try {
      final snap = await _db.child('booking_reservations').get();
      if (!snap.exists || snap.value == null || snap.value is! Map) return 0;

      final now = DateTime.now();
      int count = 0;

      final byCourse = Map<dynamic, dynamic>.from(snap.value as Map);

      for (final courseEntry in byCourse.entries) {
        final courseNode = courseEntry.value;
        if (courseNode is! Map) continue;

        final byDate = Map<dynamic, dynamic>.from(courseNode);

        for (final dateEntry in byDate.entries) {
          final dayKey = dateEntry.key.toString();
          final dateNode = dateEntry.value;
          if (dateNode is! Map) continue;

          final byTime = Map<dynamic, dynamic>.from(dateNode);

          for (final timeEntry in byTime.entries) {
            final hhmm = timeEntry.key.toString();
            final slotNode = timeEntry.value;
            if (slotNode is! Map) continue;
            final dt = _parseBookingSlotStart(dayKey, hhmm);
            if (dt == null) continue;

            bool isTeacherSlot(
              Map<dynamic, dynamic> rawSlot,
              String fallbackId,
            ) {
              final teacherId =
                  (rawSlot['teacherId'] ??
                          rawSlot['teacherUid'] ??
                          rawSlot['teacher_id'] ??
                          fallbackId)
                      .toString()
                      .trim();
              return teacherId == teacherUid;
            }

            final slot = Map<dynamic, dynamic>.from(slotNode);
            final looksLikeDirectSlot =
                slot.containsKey('teacherId') ||
                slot.containsKey('teacherUid') ||
                slot.containsKey('teacher_id') ||
                slot.containsKey('learners') ||
                slot.containsKey('sessionNo');

            if (looksLikeDirectSlot) {
              if (isTeacherSlot(slot, '') && dt.isAfter(now)) {
                count += 1;
              }
              continue;
            }

            for (final teacherEntry in slot.entries) {
              final nested = teacherEntry.value;
              if (nested is! Map) continue;
              if (isTeacherSlot(
                    Map<dynamic, dynamic>.from(nested),
                    teacherEntry.key.toString(),
                  ) &&
                  dt.isAfter(now)) {
                count += 1;
              }
            }
          }
        }
      }

      return count;
    } catch (_) {
      return 0;
    }
  }

  Future<List<_HomeUpcomingClass>> _loadNextUpcomingClassesForHome(
    String teacherUid,
  ) async {
    try {
      final identity = await _loadTeacherIdentityForHome(teacherUid);
      final snap = await _db.child(classesNode).get();
      if (!snap.exists || snap.value == null || snap.value is! Map) {
        final emptySnapshot = TeacherScheduleDataService.buildWidgetSnapshot(
          teacherName: identity.name,
          allOccurrences: const <TeacherScheduleOccurrence>[],
        );
        unawaited(
          TeacherScheduleWidgetService.instance.publishSnapshot(emptySnapshot),
        );
        return const [];
      }

      final raw = Map<dynamic, dynamic>.from(snap.value as Map);
      final now = DateTime.now();
      final candidates = <_HomeUpcomingClass>[];
      final courseMeta =
          <String, ({String classId, String code, String title})>{};

      for (final entry in raw.entries) {
        final value = entry.value;
        if (value is! Map) continue;

        final c = Map<String, dynamic>.from(value);
        if (!_matchesTeacherForHome(
          c,
          teacherUid: teacherUid,
          teacherName: identity.name,
          teacherSerial: identity.serial,
        )) {
          continue;
        }

        final courseId = (c['course_id'] ?? '').toString().trim();
        if (courseId.isNotEmpty && !courseMeta.containsKey(courseId)) {
          courseMeta[courseId] = (
            classId: (c['class_id'] ?? c['id'] ?? '').toString().trim(),
            code: (c['course_code'] ?? '').toString().trim(),
            title: (c['course_title'] ?? '').toString().trim(),
          );
        }

        final occurrences = _generateOccurrencesForHome(c);

        for (final occ in occurrences) {
          if (!occ.end.isAfter(now)) continue;
          candidates.add(occ);
        }
      }

      final onlineCandidates = await _loadUpcomingOnlineClassesForHome(
        teacherUid,
        courseMeta,
      );
      for (final occ in onlineCandidates) {
        if (!occ.end.isAfter(now)) continue;
        candidates.add(occ);
      }

      if (candidates.isEmpty) {
        final emptySnapshot = TeacherScheduleDataService.buildWidgetSnapshot(
          teacherName: identity.name,
          allOccurrences: const <TeacherScheduleOccurrence>[],
        );
        unawaited(
          TeacherScheduleWidgetService.instance.publishSnapshot(emptySnapshot),
        );
        return const [];
      }

      candidates.sort((a, b) => a.start.compareTo(b.start));
      final snapshot = TeacherScheduleDataService.buildWidgetSnapshot(
        teacherName: identity.name,
        allOccurrences: candidates
            .map(
              (e) => TeacherScheduleOccurrence(
                classId: e.classId,
                courseCode: e.courseCode,
                courseTitle: e.courseTitle,
                start: e.start,
                end: e.end,
                isOnline: e.isOnline,
                onlineBookingKey: '',
              ),
            )
            .toList(),
      );
      unawaited(
        TeacherScheduleWidgetService.instance.publishSnapshot(snapshot),
      );

      final upcoming = <_HomeUpcomingClass>[];
      for (final occ in candidates) {
        if (!occ.end.isAfter(now)) continue;
        upcoming.add(occ);
        if (upcoming.length >= 2) break;
      }
      return upcoming;
    } catch (_) {
      return const [];
    }
  }

  Future<List<_HomeUpcomingClass>> _loadUpcomingOnlineClassesForHome(
    String teacherUid,
    Map<String, ({String classId, String code, String title})> courseMeta,
  ) async {
    try {
      final snap = await _db.child('booking_reservations').get();
      if (!snap.exists || snap.value == null) return const [];

      return TeacherScheduleDataService.extractOnlineOccurrences(
            bookingData: snap.value,
            rawClasses: [
              for (final entry in courseMeta.entries)
                <String, dynamic>{
                  'course_id': entry.key,
                  'class_id': entry.value.classId,
                  'course_code': entry.value.code,
                  'course_title': entry.value.title,
                },
            ],
            isAdminViewer: false,
            viewerUid: teacherUid,
            recentCutoff: const Duration(days: 0),
          )
          .where((e) => e.start.isAfter(DateTime.now()))
          .map(
            (e) => _HomeUpcomingClass(
              classId: e.classId,
              courseCode: e.courseCode,
              courseTitle: e.courseTitle,
              start: e.start,
              end: e.end,
              isOnline: true,
            ),
          )
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<_HomeTeacherIdentity> _loadTeacherIdentityForHome(String uid) async {
    final identity = await TeacherScheduleDataService.loadViewerIdentity(uid);
    return _HomeTeacherIdentity(name: identity.name, serial: identity.serial);
  }

  bool _matchesTeacherForHome(
    Map<String, dynamic> classData, {
    required String teacherUid,
    required String teacherName,
    required String teacherSerial,
  }) {
    return TeacherScheduleDataService.matchesTeacherClass(
      classData,
      teacherUid: teacherUid,
      teacherName: teacherName,
      teacherSerial: teacherSerial,
    );
  }

  List<_HomeUpcomingClass> _generateOccurrencesForHome(
    Map<String, dynamic> cls,
  ) {
    return TeacherScheduleDataService.generateOccurrences(
          cls,
          historyWindow: const Duration(days: 14),
        )
        .map(
          (e) => _HomeUpcomingClass(
            classId: e.classId,
            courseCode: e.courseCode,
            courseTitle: e.courseTitle,
            start: e.start,
            end: e.end,
            isOnline: e.isOnline,
          ),
        )
        .toList();
  }

  int _countNotDoneReminders(dynamic snapshotValue) {
    return NotificationCounterService.reminderCounts(
      snapshotValue,
    ).pendingCount;
  }

  int _countUnreadMail(dynamic snapshotValue) {
    return NotificationCounterService.mailUnread(
      snapshotValue,
      excludeHomework: true,
    );
  }

  bool _isHomeworkThreadMeta(Map<String, dynamic> m) {
    final type = (m['type'] ?? '').toString().trim().toLowerCase();
    if (type == 'homework') return true;
    final homeworkRef = (m['homeworkRef'] ?? '').toString().trim();
    if (homeworkRef.isNotEmpty) return true;
    final subject = (m['subject'] ?? '').toString().trim().toLowerCase();
    if (subject.startsWith('[hw]')) return true;
    return false;
  }

  Future<int> _countUnreviewedHomework(dynamic snapshotValue) async {
    if (snapshotValue is! Map) return 0;

    final threadIds = <String>[];
    snapshotValue.forEach((k, v) {
      if (v is! Map) return;
      final m = v.map((kk, vv) => MapEntry(kk.toString(), vv));
      if (m['deletedAt'] != null) return;
      if (!_isHomeworkThreadMeta(m)) return;
      final tid = k.toString().trim();
      if (tid.isNotEmpty) threadIds.add(tid);
    });

    if (threadIds.isEmpty) return 0;

    final checks = threadIds.map((threadId) async {
      try {
        final tSnap = await _db.child('mail_threads/$threadId').get();
        if (!tSnap.exists || tSnap.value is! Map) return 0;
        final t = (tSnap.value as Map).map((k, v) => MapEntry('$k', v));
        final hwRefPath = (t['homeworkRef'] ?? '').toString().trim();
        if (hwRefPath.isEmpty) return 1;

        final hwSnap = await _db.child(hwRefPath).get();
        if (!hwSnap.exists || hwSnap.value is! Map) return 1;

        final hw = (hwSnap.value as Map).map((k, v) => MapEntry('$k', v));
        final reviewedAt = _toInt(hw['reviewedAt']);
        final reviewStatus = (hw['reviewStatus'] ?? '')
            .toString()
            .trim()
            .toLowerCase();
        final reviewed = reviewedAt > 0 || reviewStatus.isNotEmpty;
        return reviewed ? 0 : 1;
      } catch (_) {
        return 1;
      }
    }).toList();

    final parts = await Future.wait(checks);
    return parts.fold<int>(0, (sum, n) => sum + n);
  }

  int _toInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  Future<String> _myDisplayName() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    final email = FirebaseAuth.instance.currentUser?.email ?? '';
    final emailPrefix = email.isNotEmpty ? email.split('@').first : '';

    if (uid == null) {
      return emailPrefix.isNotEmpty ? emailPrefix : 'Teacher';
    }

    try {
      final snap = await _db.child('users/$uid').get();
      final v = snap.value;
      if (v is Map) {
        final m = v.map((k, vv) => MapEntry(k.toString(), vv));
        final first = (m['first_name'] ?? '').toString().trim();
        final last = (m['last_name'] ?? '').toString().trim();
        final full = ('$first $last').trim();
        if (full.isNotEmpty) return full;

        final dbEmail = (m['email'] ?? '').toString().trim();
        if (dbEmail.isNotEmpty) return dbEmail.split('@').first;
      }
    } catch (_) {}

    return emailPrefix.isNotEmpty ? emailPrefix : 'Teacher';
  }

  void _openThemeSheet() {
    final p = palette;

    Future<void> pickTheme(AppThemeMode mode) async {
      await appThemeController.setTheme(mode);
      if (!mounted) return;
      setState(() {});
      Navigator.of(context).pop();
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: p.appBg,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.75,
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Choose Theme',
                      style: TextStyle(
                        color: p.primary,
                        fontWeight: FontWeight.w900,
                        fontSize: 18,
                      ),
                    ),
                    const SizedBox(height: 14),
                    ...AppThemeMode.values.map((mode) {
                      final previewPalette = appThemeController.paletteForMode(
                        mode,
                      );

                      return Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _ThemeChoiceTile(
                          title: appThemeController.themeTitle(mode),
                          subtitle: appThemeController.themeSubtitle(mode),
                          selected: appThemeController.mode == mode,
                          preview1: previewPalette.primary,
                          preview2: previewPalette.accent,
                          onTap: () => pickTheme(mode),
                        ),
                      );
                    }),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _pushScreen(Widget screen) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

  void _openTeacherWindow(
    String windowKey,
    VoidCallback onAllowed, {
    bool requiresInternet = true,
  }) {
    Future<void> openAction() {
      return WindowAccessService.instance.guardOpen(
        context: context,
        role: AppWindowRole.teacher,
        windowKey: windowKey,
        onAllowed: onAllowed,
      );
    }

    if (!requiresInternet) {
      unawaited(openAction());
      return;
    }

    unawaited(OfflineActionGuard.run(context, openAction));
  }

  void _openProfileScreen() {
    _openTeacherWindow(
      AppWindowKeys.teacherProfile,
      () => _pushScreen(const TeacherProfileScreen()),
    );
  }

  void _openScheduleScreen() {
    _openTeacherWindow(
      AppWindowKeys.teacherSchedule,
      () => _pushScreen(const TeacherSchedule()),
    );
  }

  void _openClassesScreen() {
    _openTeacherWindow(
      AppWindowKeys.teacherClasses,
      () => _pushScreen(const TeacherClassesScreen()),
    );
  }

  void _openGamesScreen() {
    _openTeacherWindow(
      AppWindowKeys.teacherGames,
      () => _pushScreen(const TeacherGamesScreen()),
    );
  }

  void _openStoriesScreen() {
    _openTeacherWindow(
      AppWindowKeys.teacherStories,
      () => _pushScreen(TeacherStoriesScreen()),
    );
  }

  void _openOnlineAvailabilityScreen() {
    _openTeacherWindow(
      AppWindowKeys.teacherOnlineAvailability,
      () => _pushScreen(const TeacherOnlineBookingScreen()),
    );
  }

  void _openOnlineCircleScreen() {
    _openTeacherWindow(
      AppWindowKeys.teacherOnlineCircle,
      () => _pushScreen(TeacherOnlineCircleScreen()),
    );
  }

  void _openMailScreen() {
    _openTeacherWindow(
      AppWindowKeys.teacherMail,
      () => _pushScreen(const TeacherMailScreen()),
    );
  }

  void _openRemindersScreen() {
    _openTeacherWindow(
      AppWindowKeys.teacherReminders,
      () => _pushScreen(const TeacherReminderScreen()),
    );
  }

  void _openGalleryScreen() {
    _openTeacherWindow(
      AppWindowKeys.teacherGallery,
      () => _pushScreen(const TeacherPublicGalleryScreen()),
    );
  }

  void _openWagesScreen() {
    _openTeacherWindow(
      AppWindowKeys.teacherWages,
      () => _pushScreen(const TeacherWagesScreen()),
    );
  }

  void _openRegulationsScreen() {
    _openTeacherWindow(
      AppWindowKeys.teacherRegulations,
      () => _pushScreen(const TeacherRegulationsScreen()),
    );
  }

  void _openSyllabiScreen() {
    _openTeacherWindow(
      AppWindowKeys.teacherSyllabi,
      () => _pushScreen(TeacherSyllabiScreen()),
    );
  }

  void _openSharedScreen() {
    _openTeacherWindow(
      AppWindowKeys.teacherShared,
      () => _pushScreen(const TeacherSharedFilesScreen()),
    );
  }

  void _openMyPlatformScreen() {
    _openTeacherWindow(
      AppWindowKeys.teacherMyPlatform,
      () => _pushScreen(const TeacherMyPlatformScreen()),
    );
  }

  void _openHomeworkInboxScreen() {
    _openTeacherWindow(
      AppWindowKeys.teacherHomeworkInbox,
      () => _pushScreen(const TeacherHomeworkInboxScreen()),
    );
  }

  void _openThemeSettings() {
    _openTeacherWindow(
      AppWindowKeys.teacherThemeSettings,
      _openThemeSheet,
      requiresInternet: false,
    );
  }

  void _onThemeChanged() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final isWideWeb = AppResponsive.isWebDesktop(context, minWidth: 1180);
    final webDesktop = isTeacherWebDesktop(context, minWidth: 1280);
    final basePagePadding = AppResponsive.pagePadding(
      context,
      phone: 16,
      tablet: 18,
      desktop: 24,
      largeDesktop: 28,
      topPhone: 14,
      topTablet: 16,
      topDesktop: 18,
      topLargeDesktop: 22,
      bottomPhone: 24,
      bottomTablet: 28,
      bottomDesktop: 36,
      bottomLargeDesktop: 40,
    );
    final pagePadding = EdgeInsets.fromLTRB(
      basePagePadding.left,
      basePagePadding.top,
      basePagePadding.right,
      100,
    );

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - _lastBackPressMs < 1800) {
          await SystemNavigator.pop();
          return;
        }
        _lastBackPressMs = now;
        AppToast.show(context, 'Press back again to close app');
      },
      child: Scaffold(
        key: _scaffoldKey,
        backgroundColor: p.appBg,
        drawer: webDesktop
            ? null
            : _TeacherDrawer(
                palette: p,
                onOpenProfile: _openProfileScreen,
                onOpenSchedule: _openScheduleScreen,
                onOpenClasses: _openClassesScreen,
                onOpenGames: _openGamesScreen,
                onOpenStories: _openStoriesScreen,
                onOpenOnlineBooking: _openOnlineAvailabilityScreen,
                onOpenOnlineCircle: _openOnlineCircleScreen,
                onOpenMail: _openMailScreen,
                onOpenReminders: _openRemindersScreen,
                onOpenGallery: _openGalleryScreen,
                onOpenWages: _openWagesScreen,
                onOpenRegulations: _openRegulationsScreen,
                onOpenSyllabi: _openSyllabiScreen,
                onOpenShared: _openSharedScreen,
                onOpenMyPlatform: _openMyPlatformScreen,
                onOpenThemeSettings: _openThemeSettings,
                onLogout: () => _logout(context),
              ),
        appBar: AppBar(
          backgroundColor: Colors.white,
          elevation: 0,
          centerTitle: false,
          surfaceTintColor: Colors.white,
          leading: webDesktop
              ? null
              : IconButton(
                  key: _menuButtonKey,
                  icon: Icon(TeacherIcons.menu, color: p.primary),
                  onPressed: () => _scaffoldKey.currentState?.openDrawer(),
                ),
          title: FutureBuilder<String>(
            future: _displayNameFuture,
            builder: (context, snap) {
              final name = (snap.data ?? '').trim();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Teacher Dashboard',
                    style: TextStyle(
                      color: p.primary,
                      fontWeight: FontWeight.w900,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    name.isNotEmpty ? name : 'Teacher',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: p.text.withValues(alpha: 0.72),
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                ],
              );
            },
          ),
          actions: [
            if (webDesktop)
              IconButton(
                tooltip: 'Theme',
                icon: Icon(TeacherIcons.theme, color: p.primary),
                onPressed: _openThemeSettings,
              ),
            IconButton(
              tooltip: 'Logout',
              icon: Icon(TeacherIcons.logout, color: p.accent),
              onPressed: () => _logout(context),
            ),
          ],
        ),
        body: teacherWebBodyFrame(
          context: context,
          maxWidth: 1760,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (webDesktop)
                _TeacherHomeWebRail(
                  palette: p,
                  onOpenClasses: _openClassesScreen,
                  onOpenSchedule: _openScheduleScreen,
                  onOpenMail: _openMailScreen,
                  onOpenReminders: _openRemindersScreen,
                  onOpenBooking: _openOnlineAvailabilityScreen,
                  onOpenGallery: _openGalleryScreen,
                  onOpenSyllabi: _openSyllabiScreen,
                  onOpenWages: _openWagesScreen,
                  onLogout: () => _logout(context),
                ),
              if (webDesktop) const SizedBox(width: 14),
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: IgnorePointer(
                        child: Opacity(
                          opacity: 0.05,
                          child: Center(
                            child: Image.asset(
                              'assets/images/ybs_logo.png',
                              width: 280,
                              errorBuilder: (_, _, _) =>
                                  const SizedBox.shrink(),
                            ),
                          ),
                        ),
                      ),
                    ),
                    RefreshIndicator(
                      onRefresh: () async {
                        if (!OfflineActionGuard.ensureOnline(context)) return;
                        await _refreshHome();
                      },
                      child: ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: pagePadding,
                        children: [
                          const OfflineNoticeBanner(),
                          FutureBuilder<String>(
                            future: _displayNameFuture,
                            builder: (context, snap) {
                              final name = (snap.data ?? 'Teacher').trim();
                              return KeyedSubtree(
                                key: _heroCardKey,
                                child: _HeroSummaryCard(
                                  palette: p,
                                  teacherName: name.isEmpty ? 'Teacher' : name,
                                  onOpenProfile: _openProfileScreen,
                                  onOpenSchedule: _openScheduleScreen,
                                ),
                              );
                            },
                          ),
                          SizedBox(height: isWideWeb ? 16 : 14),
                          Row(
                            children: [
                              Expanded(
                                flex: 1,
                                child: StreamBuilder<DatabaseEvent>(
                                  stream: _mailIndexStream,
                                  builder: (context, snap) {
                                    final unread = _countUnreadMail(
                                      snap.data?.snapshot.value,
                                    );
                                    return KeyedSubtree(
                                      key: _inboxCardKey,
                                      child: _MiniStatCard(
                                        palette: p,
                                        value: unread == 0 ? '0' : '$unread',
                                        icon: TeacherIcons.mailStat,
                                        badgeCount: unread,
                                        badgeColor: Colors.red,
                                        onTap: _openMailScreen,
                                      ),
                                    );
                                  },
                                ),
                              ),
                              SizedBox(width: isWideWeb ? 16 : 8),
                              Expanded(
                                flex: 1,
                                child: StreamBuilder<DatabaseEvent>(
                                  stream: _mailIndexStream,
                                  builder: (context, snap) {
                                    return FutureBuilder<int>(
                                      future: _countUnreviewedHomework(
                                        snap.data?.snapshot.value,
                                      ),
                                      builder: (context, homeworkSnap) {
                                        final unreviewed =
                                            homeworkSnap.data ?? 0;
                                        return KeyedSubtree(
                                          key: _homeworkCardKey,
                                          child: _MiniStatCard(
                                            palette: p,
                                            value: unreviewed == 0
                                                ? '0'
                                                : '$unreviewed',
                                            icon: TeacherIcons.homeworkStat,
                                            badgeCount: unreviewed,
                                            badgeColor: const Color(0xFFD97706),
                                            onTap: _openHomeworkInboxScreen,
                                          ),
                                        );
                                      },
                                    );
                                  },
                                ),
                              ),
                              SizedBox(width: isWideWeb ? 16 : 8),
                              Expanded(
                                flex: 1,
                                child: StreamBuilder<DatabaseEvent>(
                                  stream: _remindersStream,
                                  builder: (context, snap) {
                                    final pending = _countNotDoneReminders(
                                      snap.data?.snapshot.value,
                                    );
                                    return KeyedSubtree(
                                      key: _remindersCardKey,
                                      child: _MiniStatCard(
                                        palette: p,
                                        value: pending == 0 ? '0' : '$pending',
                                        icon: TeacherIcons.reminderStat,
                                        badgeCount: pending,
                                        badgeColor: p.accent,
                                        onTap: _openRemindersScreen,
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 14),
                          FutureBuilder<_ClassesSummary>(
                            future: _classesSummaryFuture,
                            builder: (context, classSnap) {
                              final s =
                                  classSnap.data ??
                                  const _ClassesSummary(
                                    classesCount: 0,
                                    learnersCount: 0,
                                  );

                              return FutureBuilder<int>(
                                future: _upcomingOnlineCountFuture,
                                builder: (context, onlineSnap) {
                                  final upcoming = onlineSnap.data ?? 0;

                                  return KeyedSubtree(
                                    key: _overviewPanelKey,
                                    child: _OverviewPanel(
                                      palette: p,
                                      classesCount: s.classesCount,
                                      learnersCount: s.learnersCount,
                                      upcomingOnlineCount: upcoming,
                                      onOpenClasses: () => _openTeacherWindow(
                                        AppWindowKeys.teacherClasses,
                                        () => _pushScreen(
                                          const TeacherClassesScreen(
                                            initialMainTab: 0,
                                          ),
                                        ),
                                      ),
                                      onOpenOnline: () => _openTeacherWindow(
                                        AppWindowKeys.teacherOnlineAvailability,
                                        () => _pushScreen(
                                          const TeacherClassesScreen(
                                            initialMainTab: 1,
                                            initialOnlineTab: 2,
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              );
                            },
                          ),
                          const SizedBox(height: 12),
                          FutureBuilder<List<_HomeUpcomingClass>>(
                            future: _nextUpcomingClassesFuture,
                            builder: (context, snap) {
                              return KeyedSubtree(
                                key: _nextClassCardKey,
                                child: _NextComingClassCard(
                                  palette: p,
                                  upcomingClasses: snap.data ?? const [],
                                  onTapClass: (occ) {
                                    if (occ.isOnline) {
                                      _openTeacherWindow(
                                        AppWindowKeys.teacherOnlineAvailability,
                                        () => _pushScreen(
                                          const TeacherClassesScreen(
                                            initialMainTab: 1,
                                            initialOnlineTab: 2,
                                          ),
                                        ),
                                      );
                                      return;
                                    }
                                    _openScheduleScreen();
                                  },
                                  onTapTake: _openUpcomingTake,
                                  onTapProgress: _openUpcomingProgress,
                                  onTapEmpty: _openScheduleScreen,
                                ),
                              );
                            },
                          ),
                          if (webDesktop) ...[
                            const SizedBox(height: 14),
                            Text(
                              'Quick Actions',
                              style: TextStyle(
                                color: p.primary,
                                fontWeight: FontWeight.w900,
                                fontSize: 14,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Wrap(
                              spacing: 10,
                              runSpacing: 10,
                              children: [
                                _WebQuickActionTile(
                                  palette: p,
                                  icon: TeacherIcons.onlineBooking,
                                  title: 'Online Booking',
                                  onTap: _openOnlineAvailabilityScreen,
                                ),
                                _WebQuickActionTile(
                                  palette: p,
                                  icon: TeacherIcons.gallery,
                                  title: 'Gallery',
                                  onTap: _openGalleryScreen,
                                ),
                                _WebQuickActionTile(
                                  palette: p,
                                  icon: TeacherIcons.syllabi,
                                  title: 'Syllabi',
                                  onTap: _openSyllabiScreen,
                                ),
                                _WebQuickActionTile(
                                  palette: p,
                                  icon: TeacherIcons.wages,
                                  title: 'Wages',
                                  onTap: _openWagesScreen,
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (webDesktop) const SizedBox(width: 14),
              if (webDesktop)
                _TeacherHomeWebAside(
                  palette: p,
                  onOpenMail: _openMailScreen,
                  onOpenHomework: _openHomeworkInboxScreen,
                  onOpenReminders: _openRemindersScreen,
                  onOpenClasses: _openClassesScreen,
                ),
            ],
          ),
        ),
      ),
    );
  }

  _HomePalette _toHomePalette(AppPalette p) {
    return _HomePalette(
      primary: p.primary,
      accent: p.accent,
      text: p.text,
      appBg: p.appBg,
      cardBg: p.cardBg,
      border: p.border,
      soft: p.soft,
    );
  }
}

class _HomePalette {
  const _HomePalette({
    required this.primary,
    required this.accent,
    required this.text,
    required this.appBg,
    required this.cardBg,
    required this.border,
    required this.soft,
  });

  final Color primary;
  final Color accent;
  final Color text;
  final Color appBg;
  final Color cardBg;
  final Color border;
  final Color soft;
}

class _ClassesSummary {
  const _ClassesSummary({
    required this.classesCount,
    required this.learnersCount,
  });

  final int classesCount;
  final int learnersCount;
}

class _HomeUpcomingClass {
  const _HomeUpcomingClass({
    required this.classId,
    required this.courseCode,
    required this.courseTitle,
    required this.start,
    required this.end,
    this.isOnline = false,
  });

  final String classId;
  final String courseCode;
  final String courseTitle;
  final DateTime start;
  final DateTime end;
  final bool isOnline;
}

class _HomeTeacherIdentity {
  const _HomeTeacherIdentity({required this.name, required this.serial});

  final String name;
  final String serial;
}

class _HomeAttendanceReminder {
  const _HomeAttendanceReminder({
    required this.classData,
    required this.occurrence,
  });

  final Map<String, dynamic> classData;
  final _HomeUpcomingClass occurrence;

  String get reminderKey =>
      '${occurrence.classId}@@${DateFormat('yyyy-MM-dd').format(occurrence.start)}';

  String get displayTitle {
    if (occurrence.courseCode.isNotEmpty) return occurrence.courseCode;
    if (occurrence.courseTitle.isNotEmpty) return occurrence.courseTitle;
    return 'This class';
  }
}

class _TeacherHomeWebRail extends StatelessWidget {
  const _TeacherHomeWebRail({
    required this.palette,
    required this.onOpenClasses,
    required this.onOpenSchedule,
    required this.onOpenMail,
    required this.onOpenReminders,
    required this.onOpenBooking,
    required this.onOpenGallery,
    required this.onOpenSyllabi,
    required this.onOpenWages,
    required this.onLogout,
  });

  final _HomePalette palette;
  final VoidCallback onOpenClasses;
  final VoidCallback onOpenSchedule;
  final VoidCallback onOpenMail;
  final VoidCallback onOpenReminders;
  final VoidCallback onOpenBooking;
  final VoidCallback onOpenGallery;
  final VoidCallback onOpenSyllabi;
  final VoidCallback onOpenWages;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 278,
      child: Container(
        margin: const EdgeInsets.fromLTRB(8, 6, 0, 6),
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: palette.border.withValues(alpha: 0.9)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Teacher Tools',
              style: TextStyle(
                color: palette.primary,
                fontWeight: FontWeight.w900,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: ListView(
                children: [
                  _DrawerTile(
                    palette: palette,
                    icon: TeacherIcons.classes,
                    title: 'My Classes',
                    onTap: onOpenClasses,
                  ),
                  _DrawerTile(
                    palette: palette,
                    icon: TeacherIcons.schedule,
                    title: 'Schedule',
                    onTap: onOpenSchedule,
                  ),
                  _DrawerTile(
                    palette: palette,
                    icon: TeacherIcons.mail,
                    title: 'Mail',
                    onTap: onOpenMail,
                  ),
                  _DrawerTile(
                    palette: palette,
                    icon: TeacherIcons.reminders,
                    title: 'Reminders',
                    onTap: onOpenReminders,
                  ),
                  _DrawerTile(
                    palette: palette,
                    icon: TeacherIcons.onlineBooking,
                    title: 'Online Booking',
                    onTap: onOpenBooking,
                  ),
                  _DrawerTile(
                    palette: palette,
                    icon: TeacherIcons.gallery,
                    title: 'Gallery',
                    onTap: onOpenGallery,
                  ),
                  _DrawerTile(
                    palette: palette,
                    icon: TeacherIcons.syllabi,
                    title: 'Syllabi',
                    onTap: onOpenSyllabi,
                  ),
                  _DrawerTile(
                    palette: palette,
                    icon: TeacherIcons.wages,
                    title: 'Wages',
                    onTap: onOpenWages,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            _DrawerTile(
              palette: palette,
              icon: TeacherIcons.logout,
              title: 'Logout',
              onTap: onLogout,
            ),
          ],
        ),
      ),
    );
  }
}

class _TeacherHomeWebAside extends StatelessWidget {
  const _TeacherHomeWebAside({
    required this.palette,
    required this.onOpenMail,
    required this.onOpenHomework,
    required this.onOpenReminders,
    required this.onOpenClasses,
  });

  final _HomePalette palette;
  final VoidCallback onOpenMail;
  final VoidCallback onOpenHomework;
  final VoidCallback onOpenReminders;
  final VoidCallback onOpenClasses;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 300,
      child: Container(
        margin: const EdgeInsets.fromLTRB(0, 6, 8, 6),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: palette.border.withValues(alpha: 0.9)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Pinned Actions',
              style: TextStyle(
                color: palette.primary,
                fontWeight: FontWeight.w900,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 10),
            _DrawerTile(
              palette: palette,
              icon: TeacherIcons.mail,
              title: 'Open Mail',
              onTap: onOpenMail,
            ),
            _DrawerTile(
              palette: palette,
              icon: TeacherIcons.homeworkStat,
              title: 'Homework Inbox',
              onTap: onOpenHomework,
            ),
            _DrawerTile(
              palette: palette,
              icon: TeacherIcons.reminderStat,
              title: 'Open Reminders',
              onTap: onOpenReminders,
            ),
            _DrawerTile(
              palette: palette,
              icon: TeacherIcons.classes,
              title: 'Open Classes',
              onTap: onOpenClasses,
            ),
            const Spacer(),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: palette.soft.withValues(alpha: 0.75),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                'Desktop layout keeps your daily tools fixed and visible.',
                style: TextStyle(
                  color: palette.text.withValues(alpha: 0.72),
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TeacherDrawer extends StatelessWidget {
  const _TeacherDrawer({
    required this.palette,
    required this.onOpenProfile,
    required this.onOpenSchedule,
    required this.onOpenClasses,
    required this.onOpenGallery,
    required this.onOpenOnlineBooking,
    required this.onOpenOnlineCircle,
    required this.onOpenMail,
    required this.onOpenReminders,
    required this.onOpenWages,
    required this.onOpenRegulations,
    required this.onOpenSyllabi,
    required this.onOpenThemeSettings,
    required this.onOpenShared,
    required this.onOpenMyPlatform,
    required this.onLogout,
    required this.onOpenGames,
    required this.onOpenStories,
  });

  final _HomePalette palette;
  final VoidCallback onOpenProfile;
  final VoidCallback onOpenSchedule;
  final VoidCallback onOpenClasses;
  final VoidCallback onOpenGallery;
  final VoidCallback onOpenOnlineBooking;
  final VoidCallback onOpenOnlineCircle;
  final VoidCallback onOpenMail;
  final VoidCallback onOpenReminders;
  final VoidCallback onOpenWages;
  final VoidCallback onOpenRegulations;
  final VoidCallback onOpenSyllabi;
  final VoidCallback onOpenThemeSettings;
  final VoidCallback onOpenShared;
  final VoidCallback onOpenMyPlatform;
  final VoidCallback onOpenGames;
  final VoidCallback onOpenStories;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    return Drawer(
      backgroundColor: palette.appBg,
      child: SafeArea(
        child: Column(
          children: [
            Container(
              width: double.infinity,
              margin: const EdgeInsets.all(14),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: palette.primary,
                borderRadius: BorderRadius.circular(24),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CircleAvatar(
                    radius: 24,
                    backgroundColor: Colors.white24,
                    child: Icon(
                      TeacherIcons.classes,
                      color: Colors.white,
                      size: 28,
                    ),
                  ),
                  SizedBox(height: 12),
                  Text(
                    'Teacher Menu',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                      fontSize: 18,
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    'Compact dashboard navigation',
                    style: TextStyle(
                      color: Colors.white70,
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
                children: [
                  _DrawerTile(
                    palette: palette,
                    icon: TeacherIcons.profile,
                    title: 'Profile',
                    onTap: () {
                      Navigator.of(context).pop();
                      onOpenProfile();
                    },
                  ),
                  _DrawerTile(
                    palette: palette,
                    icon: TeacherIcons.calendarSchedule,
                    title: 'Schedule',
                    onTap: () {
                      Navigator.of(context).pop();
                      onOpenSchedule();
                    },
                  ),
                  _DrawerTile(
                    palette: palette,
                    icon: TeacherIcons.classes,
                    title: 'My Classes',
                    onTap: () {
                      Navigator.of(context).pop();
                      onOpenClasses();
                    },
                  ),
                  _DrawerTile(
                    palette: palette,
                    icon: TeacherIcons.gallery,
                    title: 'Gallery',
                    subtitle: 'My learners and teachers',
                    onTap: () {
                      Navigator.of(context).pop();
                      onOpenGallery();
                    },
                  ),
                  _DrawerTile(
                    palette: palette,
                    icon: TeacherIcons.games,
                    title: 'Games',
                    onTap: () {
                      Navigator.of(context).pop();
                      onOpenGames();
                    },
                  ),
                  _DrawerTile(
                    palette: palette,
                    icon: TeacherIcons.stories,
                    title: 'Stories',
                    onTap: () {
                      Navigator.of(context).pop();
                      onOpenStories();
                    },
                  ),
                  _DrawerTile(
                    palette: palette,
                    icon: TeacherIcons.onlineBooking,
                    title: 'Online Availability',
                    onTap: () {
                      Navigator.of(context).pop();
                      onOpenOnlineBooking();
                    },
                  ),
                  _DrawerTile(
                    palette: palette,
                    icon: TeacherIcons.onlineCircle,
                    title: 'Online Circle',
                    onTap: () {
                      Navigator.of(context).pop();
                      onOpenOnlineCircle();
                    },
                  ),
                  _DrawerTile(
                    palette: palette,
                    icon: TeacherIcons.mail,
                    title: 'Mail',
                    onTap: () {
                      Navigator.of(context).pop();
                      onOpenMail();
                    },
                  ),
                  _DrawerTile(
                    palette: palette,
                    icon: TeacherIcons.reminders,
                    title: 'Reminders',
                    onTap: () {
                      Navigator.of(context).pop();
                      onOpenReminders();
                    },
                  ),
                  _DrawerTile(
                    palette: palette,
                    icon: TeacherIcons.wages,
                    title: 'Wages',
                    onTap: () {
                      Navigator.of(context).pop();
                      onOpenWages();
                    },
                  ),
                  _DrawerTile(
                    palette: palette,
                    icon: TeacherIcons.regulations,
                    title: 'Regulations',
                    onTap: () {
                      Navigator.of(context).pop();
                      onOpenRegulations();
                    },
                  ),
                  _DrawerTile(
                    palette: palette,
                    icon: TeacherIcons.syllabi,
                    title: 'Syllabi',
                    onTap: () {
                      Navigator.of(context).pop();
                      onOpenSyllabi();
                    },
                  ),
                  _DrawerTile(
                    palette: palette,
                    icon: TeacherIcons.shared,
                    title: 'Shared',
                    subtitle: 'Shared files between teachers',
                    onTap: () {
                      Navigator.of(context).pop();
                      onOpenShared();
                    },
                  ),
                  _DrawerTile(
                    palette: palette,
                    icon: TeacherIcons.myPlatform,
                    title: 'My Platform',
                    subtitle: 'Assigned course comments and reviews',
                    onTap: () {
                      Navigator.of(context).pop();
                      onOpenMyPlatform();
                    },
                  ),
                  _DrawerTile(
                    palette: palette,
                    icon: TeacherIcons.theme,
                    title: 'Theme Settings',
                    subtitle: 'Manly / girly looks',
                    onTap: () {
                      Navigator.of(context).pop();
                      onOpenThemeSettings();
                    },
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: onLogout,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: palette.accent,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                  ),
                  icon: const Icon(TeacherIcons.logout),
                  label: const Text(
                    'Logout',
                    style: TextStyle(fontWeight: FontWeight.w900),
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

class _DrawerTile extends StatelessWidget {
  const _DrawerTile({
    required this.palette,
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle = '',
  });

  final _HomePalette palette;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: palette.border.withValues(alpha: 0.85)),
            ),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: palette.soft,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(icon, color: palette.primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          color: palette.primary,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      if (subtitle.trim().isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          subtitle,
                          style: TextStyle(
                            color: palette.text.withValues(alpha: 0.55),
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Icon(
                  TeacherIcons.chevron,
                  color: palette.text.withValues(alpha: 0.45),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HeroSummaryCard extends StatelessWidget {
  const _HeroSummaryCard({
    required this.palette,
    required this.teacherName,
    required this.onOpenProfile,
    required this.onOpenSchedule,
  });

  final _HomePalette palette;
  final String teacherName;
  final VoidCallback onOpenProfile;
  final VoidCallback onOpenSchedule;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [palette.primary, palette.primary.withValues(alpha: 0.88)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(26),
        boxShadow: [
          BoxShadow(
            color: palette.primary.withValues(alpha: 0.18),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Peace Be Upon You',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.80),
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            teacherName,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w900,
              fontSize: 24,
              height: 1.1,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _HeroActionButton(
                  label: 'Profile',
                  icon: TeacherIcons.profile,
                  fillColor: Colors.white,
                  textColor: palette.primary,
                  onTap: onOpenProfile,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _HeroActionButton(
                  label: 'Schedule',
                  icon: TeacherIcons.calendarSchedule,
                  fillColor: Colors.white12,
                  textColor: Colors.white,
                  onTap: onOpenSchedule,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HeroActionButton extends StatelessWidget {
  const _HeroActionButton({
    required this.label,
    required this.icon,
    required this.fillColor,
    required this.textColor,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final Color fillColor;
  final Color textColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: fillColor,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: textColor),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(color: textColor, fontWeight: FontWeight.w900),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OverviewPanel extends StatelessWidget {
  const _OverviewPanel({
    required this.palette,
    required this.classesCount,
    required this.learnersCount,
    required this.upcomingOnlineCount,
    required this.onOpenClasses,
    required this.onOpenOnline,
  });

  final _HomePalette palette;
  final int classesCount;
  final int learnersCount;
  final int upcomingOnlineCount;
  final VoidCallback onOpenClasses;
  final VoidCallback onOpenOnline;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: palette.cardBg,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: palette.border.withValues(alpha: 0.75)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 14,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Overview',
            style: TextStyle(
              color: palette.primary,
              fontWeight: FontWeight.w900,
              fontSize: 17,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _OverviewStatBox(
                  palette: palette,
                  label: 'Classes',
                  value: '$classesCount',
                  icon: TeacherIcons.classes,
                  onTap: onOpenClasses,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _OverviewStatBox(
                  palette: palette,
                  label: 'Learners',
                  value: '$learnersCount',
                  icon: TeacherIcons.overviewLearners,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _OverviewStatBox(
                  palette: palette,
                  label: 'Online',
                  value: '$upcomingOnlineCount',
                  icon: TeacherIcons.overviewOnline,
                  badgeCount: upcomingOnlineCount,
                  badgeColor: Colors.red,
                  onTap: onOpenOnline,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _OverviewStatBox extends StatelessWidget {
  const _OverviewStatBox({
    required this.palette,
    required this.label,
    required this.value,
    required this.icon,
    this.badgeCount = 0,
    this.badgeColor,
    this.onTap,
  });

  final _HomePalette palette;
  final String label;
  final String value;
  final IconData icon;
  final int badgeCount;
  final Color? badgeColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final content = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
      decoration: BoxDecoration(
        color: palette.soft.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Column(
            children: [
              Icon(icon, color: palette.primary, size: 20),
              const SizedBox(height: 7),
              Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: palette.primary,
                  fontWeight: FontWeight.w900,
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: palette.text.withValues(alpha: 0.65),
                  fontWeight: FontWeight.w800,
                  fontSize: 10,
                ),
              ),
            ],
          ),
          if (badgeCount > 0)
            Positioned(
              top: -6,
              right: -6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: badgeColor ?? Colors.red,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: Colors.white, width: 2),
                ),
                child: Text(
                  badgeCount > 99 ? '99+' : badgeCount.toString(),
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    fontSize: 10,
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    if (onTap == null) return content;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: content,
      ),
    );
  }
}

class _NextComingClassCard extends StatelessWidget {
  const _NextComingClassCard({
    required this.palette,
    required this.upcomingClasses,
    required this.onTapClass,
    required this.onTapTake,
    required this.onTapProgress,
    required this.onTapEmpty,
  });

  final _HomePalette palette;
  final List<_HomeUpcomingClass> upcomingClasses;
  final ValueChanged<_HomeUpcomingClass> onTapClass;
  final ValueChanged<_HomeUpcomingClass> onTapTake;
  final ValueChanged<_HomeUpcomingClass> onTapProgress;
  final VoidCallback onTapEmpty;

  String _fmtCountdown(Duration d) {
    if (d.inSeconds <= 0) return '0s';
    if (d.inDays >= 1) {
      final hours = d.inHours % 24;
      return '${d.inDays}d ${hours}h';
    }
    if (d.inHours >= 1) {
      final mins = d.inMinutes % 60;
      return '${d.inHours}h ${mins}m';
    }
    if (d.inMinutes >= 1) {
      final secs = d.inSeconds % 60;
      return '${d.inMinutes}m ${secs}s';
    }
    return '${d.inSeconds}s';
  }

  Widget _buildEmptyCard() {
    return Material(
      color: palette.cardBg,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTapEmpty,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: palette.border.withValues(alpha: 0.8)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.03),
                blurRadius: 10,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Next Coming Class',
                style: TextStyle(
                  color: palette.primary,
                  fontWeight: FontWeight.w900,
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'No upcoming classes found.',
                style: TextStyle(
                  color: palette.text.withValues(alpha: 0.70),
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
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
    final classes = upcomingClasses;

    if (classes.isEmpty) {
      return _buildEmptyCard();
    }

    return StreamBuilder<DateTime>(
      stream: Stream<DateTime>.periodic(
        const Duration(seconds: 1),
        (_) => DateTime.now(),
      ),
      initialData: DateTime.now(),
      builder: (context, snapshot) {
        final now = snapshot.data ?? DateTime.now();
        final visibleClasses = classes.where((c) => c.end.isAfter(now)).toList()
          ..sort((a, b) => a.start.compareTo(b.start));

        if (visibleClasses.isEmpty) return _buildEmptyCard();

        return Column(
          children: visibleClasses.asMap().entries.map((entry) {
            final index = entry.key;
            final c = entry.value;
            final isOnline = c.isOnline;
            final hasEnded = !c.end.isAfter(now);
            final isLive = !now.isBefore(c.start) && !hasEnded;
            final untilStart = c.start.difference(now);
            final isUpcoming = !isLive && !hasEnded && untilStart.inSeconds > 0;
            final isSoon = isUpcoming && untilStart.inSeconds <= 600;
            final isWarn = isUpcoming && untilStart.inSeconds <= 1800;

            final itemPrimary = isLive
                ? const Color(0xFF1B5E20)
                : (isOnline ? const Color(0xFF0B5E8A) : palette.primary);
            final itemSoft = isLive
                ? const Color(0xFFE8F5E9)
                : (isOnline ? const Color(0xFFEAF6FF) : palette.soft);
            final itemCardBg = isLive
                ? const Color(0xFFF1FBF3)
                : (isOnline ? const Color(0xFFF7FCFF) : palette.cardBg);
            final itemBorder = isLive
                ? const Color(0xFF9AD5AB)
                : (isOnline
                      ? const Color(0xFFB5DDF2)
                      : palette.border.withValues(alpha: 0.8));

            final countdownText = isLive
                ? 'LIVE'
                : 'Starts in ${_fmtCountdown(untilStart)}';

            final countdownBg = isLive
                ? const Color(0xFFFFEBEE)
                : (isSoon
                      ? const Color(0xFFFFEBEE)
                      : (isWarn
                            ? const Color(0xFFFFF8E1)
                            : const Color(0xFFE8F5E9)));
            final countdownBorder = isLive
                ? const Color(0xFFE57373)
                : (isSoon
                      ? const Color(0xFFE57373)
                      : (isWarn
                            ? const Color(0xFFF9A825)
                            : const Color(0xFF81C784)));
            final countdownColor = isLive
                ? const Color(0xFFB71C1C)
                : (isSoon
                      ? const Color(0xFFB71C1C)
                      : (isWarn
                            ? const Color(0xFF8D6E00)
                            : const Color(0xFF1B5E20)));
            final pulseScale = (isLive || isSoon)
                ? ((now.second % 2 == 0) ? 1.04 : 0.98)
                : 1.0;

            return Padding(
              padding: EdgeInsets.only(
                bottom: index == visibleClasses.length - 1 ? 0 : 10,
              ),
              child: Material(
                color: itemCardBg,
                borderRadius: BorderRadius.circular(20),
                child: InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: () => onTapClass(c),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: itemCardBg,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: isLive
                            ? itemBorder
                            : (isSoon ? const Color(0xFFE57373) : itemBorder),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: isLive
                              ? const Color(0xFF1B5E20).withValues(alpha: 0.10)
                              : Colors.black.withValues(alpha: 0.03),
                          blurRadius: isLive ? 14 : 10,
                          offset: const Offset(0, 5),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                index == 0
                                    ? (isOnline
                                          ? 'Next Online Class'
                                          : 'Next Coming Class')
                                    : (isOnline
                                          ? 'Upcoming Online Class'
                                          : 'Upcoming Class'),
                                style: TextStyle(
                                  color: itemPrimary,
                                  fontWeight: FontWeight.w900,
                                  fontSize: 15,
                                ),
                              ),
                            ),
                            if (isOnline)
                              Container(
                                margin: const EdgeInsets.only(right: 8),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFD8EEFD),
                                  borderRadius: BorderRadius.circular(999),
                                  border: Border.all(
                                    color: const Color(0xFFA7D4F1),
                                  ),
                                ),
                                child: const Text(
                                  'ONLINE',
                                  style: TextStyle(
                                    color: Color(0xFF0B5E8A),
                                    fontWeight: FontWeight.w900,
                                    fontSize: 10,
                                  ),
                                ),
                              ),
                            AnimatedScale(
                              scale: pulseScale,
                              duration: const Duration(milliseconds: 550),
                              curve: Curves.easeInOut,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  color: countdownBg,
                                  borderRadius: BorderRadius.circular(999),
                                  border: Border.all(color: countdownBorder),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      isLive
                                          ? TeacherIcons.liveIndicator
                                          : (isSoon
                                                ? TeacherIcons.soonWarning
                                                : TeacherIcons.countdown),
                                      size: isLive ? 8 : 14,
                                      color: isLive
                                          ? Colors.red
                                          : countdownColor,
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      countdownText,
                                      style: TextStyle(
                                        color: countdownColor,
                                        fontWeight: FontWeight.w900,
                                        fontSize: 11,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Container(
                              width: 46,
                              height: 46,
                              decoration: BoxDecoration(
                                color: itemSoft,
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Icon(
                                isOnline
                                    ? TeacherIcons.videoCall
                                    : TeacherIcons.inPerson,
                                color: itemPrimary,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    c.courseTitle.isNotEmpty
                                        ? c.courseTitle
                                        : 'Untitled Class',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: itemPrimary,
                                      fontWeight: FontWeight.w900,
                                      fontSize: 14,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    '${c.courseCode.isNotEmpty ? c.courseCode : 'No course code'} • ${DateFormat('hh:mm a').format(c.start)} - ${DateFormat('hh:mm a').format(c.end)}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: palette.text.withValues(
                                        alpha: 0.65,
                                      ),
                                      fontWeight: FontWeight.w700,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            _InfoChip(
                              palette: palette,
                              icon: TeacherIcons.nextClassCalendar,
                              text: DateFormat('EEE, MMM d').format(c.start),
                            ),
                            _InfoChip(
                              palette: palette,
                              icon: TeacherIcons.nextClassBadge,
                              text: c.isOnline
                                  ? 'Online booking'
                                  : 'In-class session',
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: () => onTapTake(c),
                                style: OutlinedButton.styleFrom(
                                  side: BorderSide(color: itemBorder),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 10,
                                  ),
                                ),
                                icon: Icon(
                                  Icons.how_to_reg_rounded,
                                  color: itemPrimary,
                                  size: 18,
                                ),
                                label: Text(
                                  'Take',
                                  style: TextStyle(
                                    color: itemPrimary,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: ElevatedButton.icon(
                                onPressed: () => onTapProgress(c),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: itemPrimary,
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 10,
                                  ),
                                ),
                                icon: const Icon(
                                  Icons.insights_rounded,
                                  size: 18,
                                ),
                                label: const Text(
                                  'Progress',
                                  style: TextStyle(fontWeight: FontWeight.w900),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        );
      },
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({
    required this.palette,
    required this.icon,
    required this.text,
  });

  final _HomePalette palette;
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final maxChipWidth = MediaQuery.sizeOf(context).width < 360 ? 170.0 : 220.0;

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxChipWidth),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: palette.soft.withValues(alpha: 0.75),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: palette.primary),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: palette.primary,
                  fontWeight: FontWeight.w800,
                  fontSize: 11,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniStatCard extends StatelessWidget {
  const _MiniStatCard({
    required this.palette,
    required this.value,
    required this.icon,
    this.onTap,
    this.badgeCount = 0,
    this.badgeColor,
  });

  final _HomePalette palette;
  final String value;
  final IconData icon;
  final VoidCallback? onTap;
  final int badgeCount;
  final Color? badgeColor;

  @override
  Widget build(BuildContext context) {
    final content = LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 112;
        final iconBoxSize = compact ? 34.0 : 42.0;
        final iconSize = compact ? 20.0 : 24.0;
        final horizontalPadding = compact ? 8.0 : 12.0;
        final verticalPadding = compact ? 10.0 : 12.0;
        final gap = compact ? 6.0 : 10.0;
        final valueFontSize = compact ? 12.0 : 13.0;
        final showChevron = onTap != null && !compact;

        return Container(
          padding: EdgeInsets.symmetric(
            horizontal: horizontalPadding,
            vertical: verticalPadding,
          ),
          decoration: BoxDecoration(
            color: palette.cardBg,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: palette.border.withValues(alpha: 0.65)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.03),
                blurRadius: 10,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Row(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    width: iconBoxSize,
                    height: iconBoxSize,
                    decoration: BoxDecoration(
                      color: palette.soft,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(icon, color: palette.primary, size: iconSize),
                  ),
                  if (badgeCount > 0)
                    Positioned(
                      right: compact ? -6 : -8,
                      top: compact ? -6 : -8,
                      child: Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: compact ? 5 : 6,
                          vertical: compact ? 1.5 : 2,
                        ),
                        decoration: BoxDecoration(
                          color: badgeColor ?? Colors.red,
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                        child: Text(
                          badgeCount > 99 ? '99+' : badgeCount.toString(),
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w900,
                            fontSize: compact ? 9 : 10,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              SizedBox(width: gap),
              Expanded(
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: palette.primary,
                    fontWeight: FontWeight.w900,
                    fontSize: valueFontSize,
                  ),
                ),
              ),
              if (showChevron)
                const Icon(TeacherIcons.chevron, color: Colors.grey),
            ],
          ),
        );
      },
    );

    if (onTap == null) return content;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: content,
    );
  }
}

class _WebQuickActionTile extends StatelessWidget {
  const _WebQuickActionTile({
    required this.palette,
    required this.icon,
    required this.title,
    required this.onTap,
  });

  final _HomePalette palette;
  final IconData icon;
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 210,
      child: Material(
        color: palette.cardBg,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: palette.border.withValues(alpha: 0.8)),
            ),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: palette.soft,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: palette.primary, size: 18),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: palette.primary,
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                    ),
                  ),
                ),
                Icon(
                  TeacherIcons.chevron,
                  size: 18,
                  color: palette.text.withValues(alpha: 0.45),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ThemeChoiceTile extends StatelessWidget {
  const _ThemeChoiceTile({
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.preview1,
    required this.preview2,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final bool selected;
  final Color preview1;
  final Color preview2;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: selected ? preview1 : const Color(0xFFD1D9E0),
              width: selected ? 1.6 : 1,
            ),
          ),
          child: Row(
            children: [
              CircleAvatar(backgroundColor: preview1, radius: 12),
              const SizedBox(width: 8),
              CircleAvatar(backgroundColor: preview2, radius: 12),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF222222),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: Colors.grey.shade600,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                selected
                    ? TeacherIcons.themeSelected
                    : TeacherIcons.themeUnselected,
                color: selected ? preview1 : Colors.grey,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
