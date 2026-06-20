// TeacherSchedule.dart
// Full replacement
// ✅ Follows app theme from app_theme.dart
// ✅ Cleaner and more professional UI
// ✅ Logged-in teacher sees only own schedule
// ✅ Admin still sees all classes
// ✅ Settings moved to gear button
// ✅ No new dependencies added

import 'dart:async';
import 'dart:io';

import 'package:android_intent_plus/android_intent.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:table_calendar/table_calendar.dart';

import '../services/notification_service.dart';
import '../services/teacher_schedule_widget_service.dart';
import '../shared/app_theme.dart';
import '../shared/offline_action_guard.dart';
import '../shared/responsive_layout.dart';
import '../shared/teacher_web_layout.dart';
import 'teacher_class_progress_screen.dart';
import 'teacher_classes.dart';
import 'teacher_learner_gallery_screen.dart';
import 'teacher_learner_profile_screen.dart';
import 'teacher_schedule_data_service.dart';
import 'take_attendance_screen.dart';

class TeacherSchedule extends StatefulWidget {
  const TeacherSchedule({super.key});

  @override
  State<TeacherSchedule> createState() => _TeacherScheduleState();
}

class _TeacherScheduleState extends State<TeacherSchedule> {
  static const String _sessionReminderKeysPref =
      'teacher_schedule_session_reminder_keys_v1';
  static const String _attendanceReminderKeysPref =
      'teacher_schedule_attendance_reminder_keys_v1';
  static const String _notifDefaultsMigratedPref =
      'teacher_schedule_notif_defaults_v1_applied';
  static const List<int> _sessionLeadPresetOptions = <int>[
    5,
    10,
    15,
    30,
    45,
    60,
  ];

  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  late final DatabaseReference _classesRef = _db.child('classes');

  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;
  bool _isCalendarExpanded = false;

  bool _dailyEnabled = false;
  bool _sessionEnabled = false;
  int _dailyReminderHour = 8;
  int _dailyReminderMinute = 0;
  int _sessionReminderMinutesBefore = 15;

  late SharedPreferences _prefs;
  bool _prefsReady = false;

  bool _didAutoApply = false;

  List<_Occ> _latestUpcoming = const [];
  List<_Occ> _latestAllOcc = const [];

  Timer? _applyDebounce;
  bool _applyInProgress = false;
  bool _applyPending = false;
  List<_Occ> _lastUpcoming = const [];
  List<_Occ> _lastAllOcc = const [];
  String _lastAppliedReminderPlanKey = '';

  final Map<String, _OccCacheEntry> _occCache = <String, _OccCacheEntry>{};
  final Map<String, Map<String, String>> _learnerMiniCache =
      <String, Map<String, String>>{};

  bool _viewerReady = false;
  bool _isAdminViewer = false;
  String _viewerUid = '';
  String _viewerName = '';
  String _viewerSerial = '';
  String _lastWidgetSnapshotPayload = '';

  @override
  void initState() {
    super.initState();
    appThemeController.addListener(_onThemeChanged);
    _boot();
  }

  @override
  void dispose() {
    appThemeController.removeListener(_onThemeChanged);
    _applyDebounce?.cancel();
    super.dispose();
  }

  void _onThemeChanged() {
    if (!mounted) return;
    setState(() {});
  }

  AppPalette get p => appThemeController.palette;

  int _sanitizeHour(int? raw) {
    if (raw == null || raw < 0 || raw > 23) return 8;
    return raw;
  }

  int _sanitizeMinute(int? raw) {
    if (raw == null || raw < 0 || raw > 59) return 0;
    return raw;
  }

  int _sanitizeSessionLeadMinutes(int? raw) {
    if (raw == null || !_sessionLeadPresetOptions.contains(raw)) {
      return 15;
    }
    return raw;
  }

  String _dailyReminderLabel() {
    return DateFormat(
      'h:mm a',
    ).format(DateTime(2000, 1, 1, _dailyReminderHour, _dailyReminderMinute));
  }

  Future<void> _boot() async {
    await NotificationService.I.init();
    await NotificationService.I.requestPermissions();

    _prefs = await SharedPreferences.getInstance();
    await _applyReminderDefaultsMigration();
    final viewer = await _loadViewerIdentity();
    if (!mounted) return;

    setState(() {
      _dailyEnabled = _prefs.getBool('reminders_daily_enabled') ?? false;
      _sessionEnabled = _prefs.getBool('reminders_session_enabled') ?? true;
      _dailyReminderHour = _sanitizeHour(_prefs.getInt('reminders_daily_hour'));
      _dailyReminderMinute = _sanitizeMinute(
        _prefs.getInt('reminders_daily_minute'),
      );
      _sessionReminderMinutesBefore = _sanitizeSessionLeadMinutes(
        _prefs.getInt('reminders_session_minutes_before'),
      );
      _prefsReady = true;
      _viewerUid = viewer.uid;
      _viewerName = viewer.name;
      _viewerSerial = viewer.serial;
      _isAdminViewer = viewer.isAdmin;
      _viewerReady = true;
    });
  }

  Future<void> _applyReminderDefaultsMigration() async {
    final migrated = _prefs.getBool(_notifDefaultsMigratedPref) ?? false;
    if (!migrated) {
      if (!_prefs.containsKey('reminders_session_enabled')) {
        await _prefs.setBool('reminders_session_enabled', true);
      }
      if (!_prefs.containsKey('reminders_daily_enabled')) {
        await _prefs.setBool('reminders_daily_enabled', false);
      }
      await _prefs.setBool(_notifDefaultsMigratedPref, true);
      return;
    }

    if (!_prefs.containsKey('reminders_session_enabled')) {
      await _prefs.setBool('reminders_session_enabled', true);
    }
    if (!_prefs.containsKey('reminders_daily_enabled')) {
      await _prefs.setBool('reminders_daily_enabled', false);
    }
  }

  Future<_ScheduleViewerIdentity> _loadViewerIdentity() async {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final viewer = await TeacherScheduleDataService.loadViewerIdentity(uid);
    return _ScheduleViewerIdentity(
      uid: viewer.uid,
      name: viewer.name,
      serial: viewer.serial,
      isAdmin: viewer.isAdmin,
    );
  }

  bool _matchesTeacherClass(Map<String, dynamic> classData) {
    return TeacherScheduleDataService.matchesTeacherClass(
      classData,
      teacherUid: _viewerUid,
      teacherName: _viewerName,
      teacherSerial: _viewerSerial,
    );
  }

  _Occ _occFromShared(TeacherScheduleOccurrence occ) {
    return _Occ(
      classId: occ.classId,
      courseCode: occ.courseCode,
      courseTitle: occ.courseTitle,
      start: occ.start,
      end: occ.end,
      isOnline: occ.isOnline,
      onlineBookingKey: occ.onlineBookingKey,
    );
  }

  void _publishWidgetSnapshot(List<_Occ> allOcc) {
    final snapshot = TeacherScheduleDataService.buildWidgetSnapshot(
      teacherName: _viewerName,
      allOccurrences: allOcc
          .map(
            (o) => TeacherScheduleOccurrence(
              classId: o.classId,
              courseCode: o.courseCode,
              courseTitle: o.courseTitle,
              start: o.start,
              end: o.end,
              isOnline: o.isOnline,
              onlineBookingKey: o.onlineBookingKey,
            ),
          )
          .toList(),
    );
    final payload = snapshot.toJson().toString();
    if (payload == _lastWidgetSnapshotPayload) return;
    _lastWidgetSnapshotPayload = payload;
    unawaited(TeacherScheduleWidgetService.instance.publishSnapshot(snapshot));
  }

  String _classCacheKey(Map<String, dynamic> cls) {
    final id = (cls['class_id'] ?? cls['id'] ?? '').toString().trim();
    if (id.isNotEmpty) return id;
    return cls.hashCode.toString();
  }

  String _classScheduleSignature(Map<String, dynamic> cls) {
    final schedule = (cls['schedule'] is Map)
        ? Map<String, dynamic>.from(cls['schedule'] as Map)
        : <String, dynamic>{};
    final sessions = schedule['sessions'];
    return [
      (cls['status'] ?? '').toString(),
      (cls['course_code'] ?? '').toString(),
      (cls['course_title'] ?? '').toString(),
      (schedule['first_session_date'] ?? '').toString(),
      (schedule['sessions_count'] ?? '').toString(),
      sessions.runtimeType.toString(),
      sessions?.toString() ?? '',
    ].join('|');
  }

  List<_Occ> _occurrencesForClassCached(Map<String, dynamic> cls) {
    final key = _classCacheKey(cls);
    final signature = _classScheduleSignature(cls);
    final cached = _occCache[key];
    if (cached != null && cached.signature == signature) {
      return cached.items;
    }

    final items = _generateOccurrences(cls);
    _occCache[key] = _OccCacheEntry(signature: signature, items: items);
    return items;
  }

  void _pruneOccCache(List<Map<String, dynamic>> classes) {
    final keep = <String>{};
    for (final c in classes) {
      keep.add(_classCacheKey(c));
    }
    _occCache.removeWhere((k, _) => !keep.contains(k));
  }

  List<_Occ> _buildReminderCandidates(List<_Occ> upcoming) {
    final now = DateTime.now();
    final maxToSchedule = _lastAllOcc.length < 30 ? _lastAllOcc.length : 30;
    return upcoming
        .where((e) => e.isOnline || _isClassEnabled(e.notificationClassId))
        .where((e) => _isDayEnabled(e.start))
        .where((e) => e.start.isAfter(now))
        .take(maxToSchedule)
        .toList();
  }

  List<_Occ> _buildAttendanceReminderCandidates(List<_Occ> allOcc) {
    final now = DateTime.now();
    return allOcc
        .where((e) => !e.isOnline)
        .where((e) => e.end.isAfter(now))
        .take(30)
        .toList();
  }

  String _reminderPlanKey(List<_Occ> candidates) {
    final sb = StringBuffer()
      ..write('d:')
      ..write(_dailyEnabled ? '1' : '0')
      ..write(';dh:')
      ..write(_dailyReminderHour)
      ..write(';dm:')
      ..write(_dailyReminderMinute)
      ..write(';s:')
      ..write(_sessionEnabled ? '1' : '0')
      ..write(';sm:')
      ..write(_sessionReminderMinutesBefore)
      ..write(';');
    for (final o in candidates) {
      sb
        ..write(o.notificationClassId)
        ..write('@')
        ..write(o.start.millisecondsSinceEpoch)
        ..write('|');
    }
    return sb.toString();
  }

  String _attendanceReminderPlanKey(List<_Occ> candidates) {
    final sb = StringBuffer()..write('attendance;');
    for (final o in candidates) {
      sb
        ..write(o.classId)
        ..write('@')
        ..write(o.start.millisecondsSinceEpoch)
        ..write('@')
        ..write(o.end.millisecondsSinceEpoch)
        ..write('|');
    }
    return sb.toString();
  }

  void _openSettingsSheet() {
    if (!_prefsReady) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return SafeArea(
              child: Container(
                decoration: BoxDecoration(
                  color: p.appBg,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(24),
                  ),
                ),
                child: Padding(
                  padding: EdgeInsets.only(
                    bottom: MediaQuery.of(context).viewInsets.bottom,
                  ),
                  child: _buildSettingsView(
                    _latestUpcoming,
                    _latestAllOcc,
                    onSheetRefresh: () => setSheetState(() {}),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _showBatteryPopupOnce() async {
    if (!Platform.isAndroid) return;
    if (!_prefsReady) return;

    final alreadyShown = _prefs.getBool('battery_popup_shown') ?? false;
    if (alreadyShown) return;

    await _prefs.setBool('battery_popup_shown', true);

    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: p.cardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'Important: Enable No Restrictions',
          style: TextStyle(color: p.primary, fontWeight: FontWeight.w900),
        ),
        content: Text(
          "To make class reminders work even when the app is closed, please set Battery to 'No restrictions' for this app.\n\nTap Open Settings → then choose: Battery → No restrictions.",
          style: TextStyle(color: p.text, fontWeight: FontWeight.w600),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
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
              Navigator.pop(context);

              const intent = AndroidIntent(
                action: 'android.settings.APPLICATION_DETAILS_SETTINGS',
                data: 'package:com.yourbridgeschool.dreamenglish',
              );
              await intent.launch();
            },
            child: const Text('Open App Settings'),
          ),
        ],
      ),
    );
  }

  String _fmtDayHeader(DateTime d) => DateFormat('EEEE, MMMM d').format(d);
  String _fmtKey(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

  bool _isClassEnabled(String classId) =>
      _prefs.getBool('remind_class_$classId') ?? true;

  bool _isDayEnabled(DateTime d) {
    final key = 'remind_day_${_fmtKey(d)}';
    return _prefs.getBool(key) ?? true;
  }

  bool _hasConflict(_Occ current, List<_Occ> allOnDay) {
    for (final other in allOnDay) {
      if (identical(current, other)) continue;
      if (current.start.isBefore(other.end) &&
          other.start.isBefore(current.end)) {
        return true;
      }
    }
    return false;
  }

  String _safeStr(dynamic v) => (v ?? '').toString().trim();

  List<_SessionLearner> _inClassLearnersFromClass(
    Map<String, dynamic> classData,
  ) {
    final learners =
        classData['learners'] ??
        classData['students'] ??
        classData['enrolled_learners'] ??
        classData['student_list'];

    final out = <_SessionLearner>[];
    if (learners is Map) {
      final raw = Map<dynamic, dynamic>.from(learners);
      for (final e in raw.entries) {
        final uid = _safeStr(e.key);
        final node = e.value;
        String name = '';
        if (node is Map) {
          final m = Map<dynamic, dynamic>.from(node);
          name = _safeStr(
            m['name'] ??
                m['full_name'] ??
                m['learner_name'] ??
                m['display_name'] ??
                m['first_name'],
          );
        } else if (node is String) {
          name = node.trim();
        }
        out.add(_SessionLearner(uid: uid, name: name));
      }
    } else if (learners is List) {
      for (final item in learners) {
        if (item == null) continue;
        if (item is Map) {
          final m = Map<dynamic, dynamic>.from(item);
          out.add(
            _SessionLearner(
              uid: _safeStr(m['uid'] ?? m['learnerUid'] ?? m['studentUid']),
              name: _safeStr(
                m['name'] ??
                    m['full_name'] ??
                    m['learner_name'] ??
                    m['display_name'] ??
                    m['first_name'],
              ),
            ),
          );
        } else {
          out.add(_SessionLearner(uid: _safeStr(item), name: ''));
        }
      }
    }

    final seen = <String>{};
    return out.where((l) {
      final key = '${l.uid}|${l.name.toLowerCase()}';
      if (seen.contains(key)) return false;
      seen.add(key);
      return true;
    }).toList();
  }

  Map<String, List<_SessionLearner>> _buildInClassLearnersByClassId(
    List<Map<String, dynamic>> classes,
  ) {
    final out = <String, List<_SessionLearner>>{};
    for (final c in classes) {
      final classId = _safeStr(c['class_id'] ?? c['id']);
      if (classId.isEmpty) continue;
      out[classId] = _inClassLearnersFromClass(c);
    }
    return out;
  }

  Map<String, List<_SessionLearner>> _buildOnlineLearnersByBookingKey(
    Object? bookingData,
  ) {
    final out = <String, List<_SessionLearner>>{};
    if (bookingData is! Map) return out;
    final byCourse = Map<dynamic, dynamic>.from(bookingData);
    for (final courseEntry in byCourse.entries) {
      final courseId = _safeStr(courseEntry.key);
      if (courseId.isEmpty || courseEntry.value is! Map) continue;
      final byDate = Map<dynamic, dynamic>.from(courseEntry.value as Map);
      for (final dateEntry in byDate.entries) {
        final dayKey = _safeStr(dateEntry.key);
        if (dateEntry.value is! Map) continue;
        final byTime = Map<dynamic, dynamic>.from(dateEntry.value as Map);
        for (final timeEntry in byTime.entries) {
          final hhmm = _safeStr(timeEntry.key);
          if (timeEntry.value is! Map) continue;
          final slotMap = Map<dynamic, dynamic>.from(timeEntry.value as Map);

          void readSlot(
            Map<dynamic, dynamic> rawSlot, {
            String fallbackTeacher = '',
          }) {
            final teacherId = _safeStr(
              rawSlot['teacherId'] ??
                  rawSlot['teacherUid'] ??
                  rawSlot['teacher_id'] ??
                  fallbackTeacher,
            );
            if (!_isAdminViewer && teacherId != _viewerUid) return;

            final learnersRaw = rawSlot['learners'];
            if (learnersRaw is! Map || learnersRaw.isEmpty) return;
            final lm = Map<dynamic, dynamic>.from(learnersRaw);
            final learners = <_SessionLearner>[];
            for (final e in lm.entries) {
              final uid = _safeStr(e.key);
              final v = e.value;
              String name = '';
              if (v is Map) {
                final m = Map<dynamic, dynamic>.from(v);
                name = _safeStr(
                  m['name'] ??
                      m['full_name'] ??
                      m['learner_name'] ??
                      m['display_name'] ??
                      m['first_name'],
                );
              } else if (v is String) {
                name = v.trim();
              }
              learners.add(_SessionLearner(uid: uid, name: name));
            }
            if (learners.isEmpty) return;
            final bookingKey = '$courseId|$dayKey|$hhmm|$teacherId';
            out[bookingKey] = learners;
          }

          final looksDirect =
              slotMap.containsKey('learners') ||
              slotMap.containsKey('teacherId') ||
              slotMap.containsKey('teacherUid') ||
              slotMap.containsKey('teacher_id');

          if (looksDirect) {
            readSlot(slotMap);
          } else {
            for (final teacherEntry in slotMap.entries) {
              final nested = teacherEntry.value;
              if (nested is! Map) continue;
              readSlot(
                Map<dynamic, dynamic>.from(nested),
                fallbackTeacher: _safeStr(teacherEntry.key),
              );
            }
          }
        }
      }
    }
    return out;
  }

  Future<Map<String, String>> _loadLearnerMini(String uid) async {
    final k = uid.trim();
    if (k.isEmpty) return const {'full': '', 'profilePhoto': '', 'examMode': ''};
    if (_learnerMiniCache.containsKey(k)) return _learnerMiniCache[k]!;
    try {
      final snap = await _db.child('users').child(k).get();
      if (snap.exists && snap.value is Map) {
        final m = Map<String, dynamic>.from(snap.value as Map);
        final examMode = m['examMode'] == true ||
            m['examMode']?.toString() == 'true';
        final out = {
          'full': '${_safeStr(m['first_name'])} ${_safeStr(m['last_name'])}'
              .trim(),
          'profilePhoto': _safeStr(m['profile_photo_url']),
          'examMode': examMode ? 'true' : '',
        };
        _learnerMiniCache[k] = out;
        return out;
      }
    } catch (_) {}
    const out = {'full': '', 'profilePhoto': '', 'examMode': ''};
    _learnerMiniCache[k] = out;
    return out;
  }

  Widget _learnerAvatar({required String profilePhotoUrl, double size = 30}) {
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
                size: size * 0.5,
                color: p.primary,
              ),
            )
          : Icon(Icons.person_rounded, size: size * 0.5, color: p.primary),
    );
  }

  void _openLearnerProfile({
    required String learnerUid,
    required String learnerName,
    bool openReportComposerOnLoad = false,
    String initialCourseTitle = '',
  }) {
    if (learnerUid.trim().isEmpty) return;

    unawaited(
      OfflineActionGuard.runExclusive(
        context,
        'teacher.schedule.profile.$learnerUid',
        () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => TeacherLearnerProfileScreen(
                learnerUid: learnerUid,
                learnerName: learnerName,
                openReportComposerOnLoad: openReportComposerOnLoad,
                initialCourseTitle: initialCourseTitle,
              ),
            ),
          );
        },
      ),
    );
  }

  void _openLearnerGallery({
    required String learnerUid,
    required String learnerName,
    required String classId,
    required String classTitle,
  }) {
    if (learnerUid.trim().isEmpty) return;

    unawaited(
      OfflineActionGuard.runExclusive(
        context,
        'teacher.schedule.gallery.$learnerUid.$classId',
        () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => TeacherLearnerGalleryScreen(
                learnerUid: learnerUid,
                learnerName: learnerName,
                classId: classId,
                classTitle: classTitle,
              ),
            ),
          );
        },
      ),
    );
  }

  void _queueApplyAllReminders({
    required List<_Occ> upcoming,
    required List<_Occ> allOcc,
  }) {
    _lastUpcoming = upcoming;
    _lastAllOcc = allOcc;

    _applyDebounce?.cancel();
    _applyDebounce = Timer(const Duration(milliseconds: 450), () async {
      await _applyAllRemindersInternal();
    });
  }

  Future<void> _applyAllRemindersInternal() async {
    if (_applyInProgress) {
      _applyPending = true;
      return;
    }
    _applyInProgress = true;

    try {
      final upcoming = _lastUpcoming;
      final reminderCandidates = _buildReminderCandidates(upcoming);
      final attendanceCandidates = _buildAttendanceReminderCandidates(
        _lastAllOcc,
      );
      final planKey = _reminderPlanKey(reminderCandidates);
      final attendancePlanKey = _attendanceReminderPlanKey(
        attendanceCandidates,
      );
      final combinedPlanKey = '$planKey::$attendancePlanKey';
      if (combinedPlanKey == _lastAppliedReminderPlanKey) {
        return;
      }

      final prevKeys =
          _prefs.getStringList(_sessionReminderKeysPref) ?? const [];
      final prevAttendanceKeys =
          _prefs.getStringList(_attendanceReminderKeysPref) ?? const [];
      final nextKeys = <String>{
        for (final o in reminderCandidates) _sessionReminderKey(o),
      };
      final nextAttendanceKeys = <String>{
        for (final o in attendanceCandidates) _attendanceReminderKey(o),
      };

      if (!_dailyEnabled) {
        await NotificationService.I.cancelDailyReminder();
      } else {
        await NotificationService.I.scheduleDailyReminder(
          hour: _dailyReminderHour,
          minute: _dailyReminderMinute,
          title: 'Classes Today',
          body: 'Open app to see today\'s schedule.',
        );
      }

      if (_sessionEnabled) {
        for (final key in prevKeys) {
          if (nextKeys.contains(key)) continue;
          final parsed = _parseSessionReminderKey(key);
          if (parsed == null) continue;
          await NotificationService.I.cancelSessionReminder(
            classId: parsed.classId,
            sessionStart: parsed.start,
          );
        }

        for (final o in reminderCandidates) {
          await NotificationService.I.scheduleSessionReminder(
            classId: o.notificationClassId,
            title: o.isOnline ? 'Online Class Starting' : 'Class Starting',
            body:
                '${o.courseCode.isEmpty ? 'Class' : o.courseCode} at ${DateFormat('hh:mm a').format(o.start)}',
            sessionStart: o.start,
            minutesBefore: _sessionReminderMinutesBefore,
          );
        }
        await _prefs.setStringList(_sessionReminderKeysPref, nextKeys.toList());
      } else {
        for (final key in prevKeys) {
          final parsed = _parseSessionReminderKey(key);
          if (parsed == null) continue;
          await NotificationService.I.cancelSessionReminder(
            classId: parsed.classId,
            sessionStart: parsed.start,
          );
        }
        await _prefs.setStringList(_sessionReminderKeysPref, const []);
      }

      for (final key in prevAttendanceKeys) {
        if (nextAttendanceKeys.contains(key)) continue;
        final parsed = _parseAttendanceReminderKey(key);
        if (parsed == null) continue;
        await NotificationService.I.cancelAttendanceReminder(
          classId: parsed.classId,
          sessionStart: parsed.start,
        );
      }

      for (final o in attendanceCandidates) {
        await NotificationService.I.scheduleAttendanceReminder(
          classId: o.classId,
          title: 'Attendance Needed',
          body:
              '${o.courseCode.isEmpty ? 'Class' : o.courseCode} just ended. Please take attendance now.',
          sessionStart: o.start,
          remindAt: o.end,
        );
      }
      await _prefs.setStringList(
        _attendanceReminderKeysPref,
        nextAttendanceKeys.toList(),
      );

      _lastAppliedReminderPlanKey = combinedPlanKey;
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Reminder sync failed: $e')));
    } finally {
      _applyInProgress = false;
      if (_applyPending) {
        _applyPending = false;
        await _applyAllRemindersInternal();
      }
    }
  }

  String _sessionReminderKey(_Occ o) {
    return '${o.notificationClassId}@@${o.start.toIso8601String()}';
  }

  ({String classId, DateTime start})? _parseSessionReminderKey(String raw) {
    final i = raw.lastIndexOf('@@');
    if (i <= 0) return null;
    final classId = raw.substring(0, i);
    final dtRaw = raw.substring(i + 2);
    final dt = DateTime.tryParse(dtRaw);
    if (classId.isEmpty || dt == null) return null;
    return (classId: classId, start: dt);
  }

  String _attendanceReminderKey(_Occ o) {
    return '${o.classId}@@${o.start.toIso8601String()}';
  }

  ({String classId, DateTime start})? _parseAttendanceReminderKey(String raw) {
    final i = raw.lastIndexOf('@@');
    if (i <= 0) return null;
    final classId = raw.substring(0, i);
    final dtRaw = raw.substring(i + 2);
    final dt = DateTime.tryParse(dtRaw);
    if (classId.isEmpty || dt == null) return null;
    return (classId: classId, start: dt);
  }

  @override
  Widget build(BuildContext context) {
    final desktopWorkspace = AppResponsive.isWebDesktop(
      context,
      minWidth: 1280,
    );

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: p.appBg,
        appBar: AppBar(
          backgroundColor: p.cardBg,
          surfaceTintColor: p.cardBg,
          elevation: 0,
          titleSpacing: 16,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Teacher Schedule',
                style: TextStyle(
                  color: p.primary,
                  fontWeight: FontWeight.w900,
                  fontSize: 18,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'Classes, attendance, and reminders',
                style: TextStyle(
                  color: p.text.withValues(alpha: 0.65),
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          actions: [
            const SizedBox.shrink(),
            IconButton(
              tooltip: 'Settings',
              icon: Icon(Icons.settings_rounded, color: p.primary),
              onPressed: _openSettingsSheet,
            ),
          ],
          bottom: TabBar(
            labelColor: p.primary,
            unselectedLabelColor: p.text.withValues(alpha: 0.65),
            indicatorColor: p.accent,
            tabs: const [
              Tab(
                text: 'Schedule',
                icon: Icon(Icons.format_list_bulleted_rounded),
              ),
              Tab(text: 'Calendar', icon: Icon(Icons.calendar_month_rounded)),
            ],
          ),
        ),
        body: teacherWebBodyFrame(
          context: context,
          maxWidth: 1560,
          child: StreamBuilder<DatabaseEvent>(
            stream: _classesRef.onValue,
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting ||
                  !_prefsReady ||
                  !_viewerReady) {
                return Center(
                  child: CircularProgressIndicator(color: p.accent),
                );
              }

              final data = snap.data?.snapshot.value;
              if (data == null) {
                return _EmptyState(
                  palette: p,
                  icon: Icons.school_outlined,
                  title: 'No classes found',
                  subtitle: 'There are no class records available yet.',
                );
              }

              final rawClasses = <Map<String, dynamic>>[];
              if (data is Map) {
                for (final v in data.values) {
                  if (v is Map) {
                    rawClasses.add(Map<String, dynamic>.from(v));
                  }
                }
              }

              if (rawClasses.isEmpty) {
                return _EmptyState(
                  palette: p,
                  icon: Icons.event_busy_rounded,
                  title: 'No classes found',
                  subtitle: 'There are no class records available yet.',
                );
              }

              if (_viewerUid.isEmpty) {
                return _EmptyState(
                  palette: p,
                  icon: Icons.lock_outline_rounded,
                  title: 'No logged-in user found',
                  subtitle: 'Please log out and log in again.',
                );
              }

              final isAdmin = _isAdminViewer;
              final visibleClasses = isAdmin
                  ? rawClasses
                  : rawClasses.where(_matchesTeacherClass).toList();

              _pruneOccCache(visibleClasses);

              return StreamBuilder<DatabaseEvent>(
                stream: _db.child('booking_reservations').onValue,
                builder: (context, bookingSnap) {
                  final allOcc = <_Occ>[];
                  for (final cls in visibleClasses) {
                    allOcc.addAll(_occurrencesForClassCached(cls));
                  }

                  final onlineOcc = _extractOnlineOccurrences(
                    bookingSnap.data?.snapshot.value,
                    rawClasses,
                  );
                  final inClassLearnersByClassId =
                      _buildInClassLearnersByClassId(visibleClasses);
                  final onlineLearnersByBookingKey =
                      _buildOnlineLearnersByBookingKey(
                        bookingSnap.data?.snapshot.value,
                      );
                  allOcc.addAll(onlineOcc);
                  allOcc.sort((a, b) => a.start.compareTo(b.start));

                  final now = DateTime.now();
                  final twoDaysAgo = now.subtract(const Duration(days: 2));
                  final recentAndUpcoming = allOcc
                      .where((o) => o.end.isAfter(twoDaysAgo))
                      .toList();

                  _latestAllOcc = allOcc;
                  _latestUpcoming = recentAndUpcoming;
                  _publishWidgetSnapshot(allOcc);

                  if (_prefsReady && !_didAutoApply) {
                    _didAutoApply = true;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!mounted) return;
                      _queueApplyAllReminders(
                        upcoming: recentAndUpcoming,
                        allOcc: allOcc,
                      );
                    });
                  }

                  if (recentAndUpcoming.isEmpty) {
                    return _EmptyState(
                      palette: p,
                      icon: Icons.schedule_rounded,
                      title: isAdmin
                          ? 'No recent or upcoming sessions'
                          : 'No recent or upcoming sessions',
                      subtitle: visibleClasses.isEmpty
                          ? 'No in-class schedules or online bookings found yet.'
                          : 'Your schedule is clear for now.',
                    );
                  }

                  final scheduleViews = TabBarView(
                    children: [
                      _buildGroupedSchedule(
                        recentAndUpcoming,
                        allOcc,
                        visibleClasses,
                        inClassLearnersByClassId,
                        onlineLearnersByBookingKey,
                      ),
                      _buildCalendarView(
                        allOcc,
                        recentAndUpcoming,
                        visibleClasses,
                        inClassLearnersByClassId,
                        onlineLearnersByBookingKey,
                      ),
                    ],
                  );

                  if (!desktopWorkspace) {
                    return Column(children: [Expanded(child: scheduleViews)]);
                  }

                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: scheduleViews),
                      Container(
                        width: 1,
                        color: p.border.withValues(alpha: 0.75),
                      ),
                      SizedBox(
                        width: 320,
                        child: ListView(
                          padding: const EdgeInsets.all(16),
                          children: [
                            _desktopScheduleSummaryCard(
                              title: 'Visible classes',
                              value: '${visibleClasses.length}',
                              subtitle: 'Classes matched to this teacher view',
                            ),
                            const SizedBox(height: 12),
                            _desktopScheduleSummaryCard(
                              title: 'Recent + upcoming',
                              value: '${recentAndUpcoming.length}',
                              subtitle:
                                  'Sessions shown in the active schedule feed',
                            ),
                            const SizedBox(height: 12),
                            _desktopScheduleSummaryCard(
                              title: 'All sessions',
                              value: '${allOcc.length}',
                              subtitle:
                                  'Includes calendar history and online occurrences',
                            ),
                            const SizedBox(height: 12),
                            OutlinedButton.icon(
                              onPressed: _openSettingsSheet,
                              icon: const Icon(Icons.settings_rounded),
                              label: const Text('Schedule settings'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildGroupedSchedule(
    List<_Occ> displayList,
    List<_Occ> allOcc,
    List<Map<String, dynamic>> visibleClasses,
    Map<String, List<_SessionLearner>> inClassLearnersByClassId,
    Map<String, List<_SessionLearner>> onlineLearnersByBookingKey,
  ) {
    if (displayList.isEmpty) {
      return _EmptyState(
        palette: p,
        icon: Icons.schedule_rounded,
        title: 'No recent or upcoming classes',
        subtitle: 'Your schedule is clear for now.',
      );
    }

    final Map<String, List<_Occ>> grouped = {};
    for (final o in displayList) {
      final header = _fmtDayHeader(o.start);
      grouped.putIfAbsent(header, () => []).add(o);
    }
    final headers = grouped.keys.toList();

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
      itemCount: headers.length,
      itemBuilder: (context, index) {
        final day = headers[index];
        final dayClasses = grouped[day]!;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              margin: EdgeInsets.only(top: index == 0 ? 0 : 12, bottom: 10),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: p.soft.withValues(alpha: 0.8),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: p.border.withValues(alpha: 0.85)),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.calendar_today_rounded,
                    size: 16,
                    color: p.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      day,
                      style: TextStyle(
                        color: p.primary,
                        fontWeight: FontWeight.w900,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  Text(
                    '${dayClasses.length} session${dayClasses.length == 1 ? '' : 's'}',
                    style: TextStyle(
                      color: p.text.withValues(alpha: 0.65),
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            ...dayClasses.map((o) {
              final isConflict = _hasConflict(o, dayClasses);
              return _SessionCard(
                key: ValueKey<String>(
                  '${o.notificationClassId}@@${o.start.toIso8601String()}',
                ),
                palette: p,
                o: o,
                learners: o.isOnline
                    ? (onlineLearnersByBookingKey[o.onlineBookingKey] ??
                          const [])
                    : (inClassLearnersByClassId[o.classId] ?? const []),
                isConflict: isConflict,
                enabled: o.isOnline
                    ? true
                    : _isClassEnabled(o.notificationClassId),
                learnerAvatarBuilder: _learnerAvatar,
                learnerMiniLoader: _loadLearnerMini,
                onLearnerProfile: (learner) {
                  final fallbackName = learner.name.trim().isEmpty
                      ? 'Learner'
                      : learner.name;
                  _openLearnerProfile(
                    learnerUid: learner.uid,
                    learnerName: fallbackName,
                  );
                },
                onLearnerReport: (learner) {
                  final fallbackName = learner.name.trim().isEmpty
                      ? 'Learner'
                      : learner.name;
                  _openLearnerProfile(
                    learnerUid: learner.uid,
                    learnerName: fallbackName,
                    openReportComposerOnLoad: true,
                    initialCourseTitle: o.courseTitle,
                  );
                },
                onLearnerGallery: (learner) {
                  final fallbackName = learner.name.trim().isEmpty
                      ? 'Learner'
                      : learner.name;
                  _openLearnerGallery(
                    learnerUid: learner.uid,
                    learnerName: fallbackName,
                    classId: o.classId,
                    classTitle: o.courseTitle,
                  );
                },
                onToggle: () {
                  if (o.isOnline) return;
                  _toggleClassNotif(o.notificationClassId, displayList, allOcc);
                },
                onAttendance: () => _openAttendance(o, visibleClasses),
                onProgress: () => _openProgress(o, visibleClasses),
                onOpenOnline: _openOnlineUpcomingTab,
              );
            }),
          ],
        );
      },
    );
  }

  Widget _desktopScheduleSummaryCard({
    required String title,
    required String value,
    required String subtitle,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: p.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: p.border.withValues(alpha: 0.88)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(color: p.primary, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 10),
          Text(
            value,
            style: TextStyle(
              color: p.accent,
              fontWeight: FontWeight.w900,
              fontSize: 28,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: TextStyle(
              color: p.text.withValues(alpha: 0.7),
              fontWeight: FontWeight.w700,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCalendarView(
    List<_Occ> allOcc,
    List<_Occ> upcoming,
    List<Map<String, dynamic>> visibleClasses,
    Map<String, List<_SessionLearner>> inClassLearnersByClassId,
    Map<String, List<_SessionLearner>> onlineLearnersByBookingKey,
  ) {
    final Map<String, List<_Occ>> byDay = {};
    for (final o in allOcc) {
      final k = _fmtKey(o.start);
      byDay.putIfAbsent(k, () => []).add(o);
    }

    final selected = _selectedDay ?? _focusedDay;
    final events = byDay[_fmtKey(selected)] ?? [];

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: Material(
            color: p.cardBg,
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () {
                setState(() => _isCalendarExpanded = !_isCalendarExpanded);
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: p.border.withValues(alpha: 0.85)),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.calendar_month_rounded,
                      size: 18,
                      color: p.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _isCalendarExpanded
                            ? 'Hide calendar to show more classes'
                            : 'Show calendar',
                        style: TextStyle(
                          color: p.primary,
                          fontWeight: FontWeight.w800,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    Icon(
                      _isCalendarExpanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      color: p.primary,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        AnimatedCrossFade(
          duration: const Duration(milliseconds: 220),
          crossFadeState: _isCalendarExpanded
              ? CrossFadeState.showFirst
              : CrossFadeState.showSecond,
          firstChild: Container(
            margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            decoration: BoxDecoration(
              color: p.cardBg,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: p.border.withValues(alpha: 0.85)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.03),
                  blurRadius: 10,
                  offset: const Offset(0, 5),
                ),
              ],
            ),
            child: TableCalendar(
              firstDay: DateTime.now().subtract(const Duration(days: 365)),
              lastDay: DateTime.now().add(const Duration(days: 365)),
              focusedDay: _focusedDay,
              selectedDayPredicate: (day) => isSameDay(selected, day),
              calendarFormat: CalendarFormat.month,
              rowHeight: 39,
              daysOfWeekHeight: 22,
              headerStyle: HeaderStyle(
                formatButtonVisible: false,
                titleCentered: true,
                titleTextStyle: TextStyle(
                  color: p.primary,
                  fontWeight: FontWeight.w900,
                  fontSize: 14,
                ),
                leftChevronIcon: Icon(
                  Icons.chevron_left_rounded,
                  color: p.primary,
                ),
                rightChevronIcon: Icon(
                  Icons.chevron_right_rounded,
                  color: p.primary,
                ),
              ),
              daysOfWeekStyle: DaysOfWeekStyle(
                weekdayStyle: TextStyle(
                  color: p.text.withValues(alpha: 0.72),
                  fontWeight: FontWeight.w700,
                ),
                weekendStyle: TextStyle(
                  color: p.text.withValues(alpha: 0.72),
                  fontWeight: FontWeight.w700,
                ),
              ),
              calendarStyle: CalendarStyle(
                defaultTextStyle: TextStyle(
                  color: p.text,
                  fontWeight: FontWeight.w700,
                ),
                weekendTextStyle: TextStyle(
                  color: p.text,
                  fontWeight: FontWeight.w700,
                ),
                todayDecoration: BoxDecoration(
                  color: p.soft,
                  shape: BoxShape.circle,
                ),
                todayTextStyle: TextStyle(
                  color: p.primary,
                  fontWeight: FontWeight.w900,
                ),
                selectedDecoration: BoxDecoration(
                  color: p.primary,
                  shape: BoxShape.circle,
                ),
                selectedTextStyle: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                ),
                outsideTextStyle: TextStyle(
                  color: p.text.withValues(alpha: 0.35),
                ),
              ),
              calendarBuilders: CalendarBuilders(
                markerBuilder: (context, day, events) {
                  final list = events.whereType<_Occ>().toList();
                  if (list.isEmpty) return null;

                  list.sort((a, b) => a.start.compareTo(b.start));
                  final dots = list.take(4).toList();

                  return Align(
                    alignment: Alignment.bottomCenter,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final e in dots)
                            Container(
                              width: 6,
                              height: 6,
                              margin: const EdgeInsets.symmetric(horizontal: 1),
                              decoration: BoxDecoration(
                                color: e.isOnline
                                    ? const Color(0xFFD32F2F)
                                    : p.accent,
                                shape: BoxShape.circle,
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
              onDaySelected: (s, f) => setState(() {
                _selectedDay = s;
                _focusedDay = f;
              }),
              eventLoader: (day) => byDay[_fmtKey(day)] ?? const [],
            ),
          ),
          secondChild: const SizedBox.shrink(),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
          child: Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  color: Color(0xFFD32F2F),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                'Red dot = Online booking',
                style: TextStyle(
                  color: p.text.withValues(alpha: 0.7),
                  fontWeight: FontWeight.w700,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: events.isEmpty
              ? _EmptyState(
                  palette: p,
                  icon: Icons.event_available_rounded,
                  title: 'No sessions on this date',
                  subtitle: 'Pick another day to view scheduled classes.',
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                  itemCount: events.length,
                  itemBuilder: (context, i) {
                    final isConflict = _hasConflict(events[i], events);
                    return _SessionCard(
                      key: ValueKey<String>(
                        '${events[i].notificationClassId}@@${events[i].start.toIso8601String()}',
                      ),
                      palette: p,
                      o: events[i],
                      learners: events[i].isOnline
                          ? (onlineLearnersByBookingKey[events[i]
                                    .onlineBookingKey] ??
                                const [])
                          : (inClassLearnersByClassId[events[i].classId] ??
                                const []),
                      isConflict: isConflict,
                      enabled: events[i].isOnline
                          ? true
                          : _isClassEnabled(events[i].notificationClassId),
                      learnerAvatarBuilder: _learnerAvatar,
                      learnerMiniLoader: _loadLearnerMini,
                      onLearnerProfile: (learner) {
                        final fallbackName = learner.name.trim().isEmpty
                            ? 'Learner'
                            : learner.name;
                        _openLearnerProfile(
                          learnerUid: learner.uid,
                          learnerName: fallbackName,
                        );
                      },
                      onLearnerReport: (learner) {
                        final fallbackName = learner.name.trim().isEmpty
                            ? 'Learner'
                            : learner.name;
                        _openLearnerProfile(
                          learnerUid: learner.uid,
                          learnerName: fallbackName,
                          openReportComposerOnLoad: true,
                          initialCourseTitle: events[i].courseTitle,
                        );
                      },
                      onLearnerGallery: (learner) {
                        final fallbackName = learner.name.trim().isEmpty
                            ? 'Learner'
                            : learner.name;
                        _openLearnerGallery(
                          learnerUid: learner.uid,
                          learnerName: fallbackName,
                          classId: events[i].classId,
                          classTitle: events[i].courseTitle,
                        );
                      },
                      onToggle: () {
                        if (events[i].isOnline) return;
                        _toggleClassNotif(
                          events[i].notificationClassId,
                          upcoming,
                          allOcc,
                        );
                      },
                      onAttendance: () =>
                          _openAttendance(events[i], visibleClasses),
                      onProgress: () =>
                          _openProgress(events[i], visibleClasses),
                      onOpenOnline: _openOnlineUpcomingTab,
                    );
                  },
                ),
        ),
      ],
    );
  }

  void _openOnlineUpcomingTab() {
    unawaited(
      OfflineActionGuard.runExclusive(
        context,
        'teacher.schedule.online_upcoming',
        () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => const TeacherClassesScreen(
                initialMainTab: 1,
                initialOnlineTab: 2,
              ),
            ),
          );
        },
      ),
    );
  }

  void _openAttendance(_Occ o, List<Map<String, dynamic>> visibleClasses) {
    final classId = o.classId;
    final classMap = visibleClasses.firstWhere(
      (c) => (c['class_id'] ?? c['id'])?.toString() == o.classId,
      orElse: () => <String, dynamic>{},
    );
    if (classMap.isEmpty) return;

    unawaited(
      OfflineActionGuard.runExclusive(
        context,
        'teacher.schedule.attendance.$classId',
        () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => TakeAttendanceScreen(classData: classMap),
            ),
          );
        },
      ),
    );
  }

  void _openProgress(_Occ o, List<Map<String, dynamic>> visibleClasses) {
    final classId = o.classId;
    final classMap = visibleClasses.firstWhere(
      (c) => (c['class_id'] ?? c['id'])?.toString() == o.classId,
      orElse: () => <String, dynamic>{},
    );
    if (classMap.isEmpty) return;

    unawaited(
      OfflineActionGuard.runExclusive(
        context,
        'teacher.schedule.progress.$classId',
        () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => TeacherClassProgressScreen(
                classId: o.classId,
                classData: classMap,
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSettingsView(
    List<_Occ> upcoming,
    List<_Occ> allOcc, {
    VoidCallback? onSheetRefresh,
  }) {
    return ListView(
      padding: const EdgeInsets.all(20),
      shrinkWrap: true,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Notifications',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                  color: p.primary,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Close',
              icon: Icon(Icons.close_rounded, color: p.primary),
              onPressed: () => Navigator.pop(context),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            color: p.cardBg,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: p.border),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.03),
                blurRadius: 10,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: p.appBg.withValues(alpha: 0.7),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: p.border),
                      ),
                      child: Column(
                        children: [
                          SwitchListTile(
                            activeThumbColor: p.accent,
                            secondary: Icon(
                              Icons.wb_sunny_rounded,
                              color: p.accent,
                            ),
                            title: Text(
                              'Daily Briefing (${_dailyReminderLabel()})',
                              style: TextStyle(
                                color: p.primary,
                                fontWeight: FontWeight.w900,
                                fontSize: 14,
                              ),
                            ),
                            subtitle: Text(
                              'A simple morning reminder to check the day schedule.',
                              style: TextStyle(
                                color: p.text.withValues(alpha: 0.65),
                                fontWeight: FontWeight.w600,
                                fontSize: 12,
                              ),
                            ),
                            value: _dailyEnabled,
                            onChanged: (v) async {
                              await _toggleDaily(v, upcoming, allOcc);
                              onSheetRefresh?.call();
                            },
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(56, 0, 12, 12),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: OutlinedButton.icon(
                                onPressed: _dailyEnabled
                                    ? () async {
                                        await _pickDailyReminderTime(
                                          upcoming,
                                          allOcc,
                                        );
                                        onSheetRefresh?.call();
                                      }
                                    : null,
                                icon: const Icon(
                                  Icons.access_time_rounded,
                                  size: 18,
                                ),
                                label: const Text('Set time'),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    Container(
                      decoration: BoxDecoration(
                        color: p.appBg.withValues(alpha: 0.7),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: p.border),
                      ),
                      child: Column(
                        children: [
                          SwitchListTile(
                            activeThumbColor: p.accent,
                            secondary: Icon(
                              Icons.notifications_active_rounded,
                              color: p.primary,
                            ),
                            title: Text(
                              'Session Alerts (${_sessionReminderMinutesBefore}m before)',
                              style: TextStyle(
                                color: p.primary,
                                fontWeight: FontWeight.w900,
                                fontSize: 14,
                              ),
                            ),
                            subtitle: Text(
                              'Get alerted shortly before each class starts.',
                              style: TextStyle(
                                color: p.text.withValues(alpha: 0.65),
                                fontWeight: FontWeight.w600,
                                fontSize: 12,
                              ),
                            ),
                            value: _sessionEnabled,
                            onChanged: (v) async {
                              await _toggleSession(v, upcoming, allOcc);
                              onSheetRefresh?.call();
                            },
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(56, 0, 12, 12),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: _sessionLeadPresetOptions
                                    .map(
                                      (minutes) => ChoiceChip(
                                        label: Text('${minutes}m'),
                                        selected:
                                            _sessionReminderMinutesBefore ==
                                            minutes,
                                        onSelected: _sessionEnabled
                                            ? (_) async {
                                                await _setSessionReminderMinutesBefore(
                                                  minutes,
                                                  upcoming,
                                                  allOcc,
                                                );
                                                onSheetRefresh?.call();
                                              }
                                            : null,
                                      ),
                                    )
                                    .toList(),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  List<_Occ> _generateOccurrences(Map<String, dynamic> cls) {
    return TeacherScheduleDataService.generateOccurrences(
      cls,
    ).map(_occFromShared).toList();
  }

  List<_Occ> _extractOnlineOccurrences(
    Object? bookingData,
    List<Map<String, dynamic>> rawClasses,
  ) {
    return TeacherScheduleDataService.extractOnlineOccurrences(
      bookingData: bookingData,
      rawClasses: rawClasses,
      isAdminViewer: _isAdminViewer,
      viewerUid: _viewerUid,
    ).map(_occFromShared).toList();
  }

  Future<void> _toggleClassNotif(
    String classId,
    List<_Occ> up,
    List<_Occ> all,
  ) async {
    if (!_prefsReady) return;
    if (classId.startsWith('online:')) return;

    final current = _isClassEnabled(classId);
    await _prefs.setBool('remind_class_$classId', !current);
    if (mounted) setState(() {});
    _queueApplyAllReminders(upcoming: up, allOcc: all);
  }

  Future<void> _toggleDaily(bool v, List<_Occ> up, List<_Occ> all) async {
    if (!_prefsReady) return;

    setState(() => _dailyEnabled = v);
    await _prefs.setBool('reminders_daily_enabled', v);
    _queueApplyAllReminders(upcoming: up, allOcc: all);
  }

  Future<void> _toggleSession(bool v, List<_Occ> up, List<_Occ> all) async {
    if (!_prefsReady) return;

    setState(() => _sessionEnabled = v);
    await _prefs.setBool('reminders_session_enabled', v);

    if (v == true) {
      await _showBatteryPopupOnce();
      await _maybeHandleExactAlarmPermission();
    }

    _queueApplyAllReminders(upcoming: up, allOcc: all);
  }

  Future<void> _pickDailyReminderTime(List<_Occ> up, List<_Occ> all) async {
    if (!_prefsReady) return;

    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: _dailyReminderHour,
        minute: _dailyReminderMinute,
      ),
    );
    if (picked == null) return;

    setState(() {
      _dailyReminderHour = picked.hour;
      _dailyReminderMinute = picked.minute;
    });
    await _prefs.setInt('reminders_daily_hour', _dailyReminderHour);
    await _prefs.setInt('reminders_daily_minute', _dailyReminderMinute);
    _queueApplyAllReminders(upcoming: up, allOcc: all);
  }

  Future<void> _setSessionReminderMinutesBefore(
    int rawMinutes,
    List<_Occ> up,
    List<_Occ> all,
  ) async {
    if (!_prefsReady) return;

    final minutes = _sanitizeSessionLeadMinutes(rawMinutes);
    if (_sessionReminderMinutesBefore == minutes) return;

    setState(() => _sessionReminderMinutesBefore = minutes);
    await _prefs.setInt('reminders_session_minutes_before', minutes);
    _queueApplyAllReminders(upcoming: up, allOcc: all);
  }

  Future<void> _maybeHandleExactAlarmPermission() async {
    try {
      final canExactNow = await NotificationService.I.canScheduleExactAlarms();
      if (canExactNow) return;

      if (!mounted) return;
      final choice = await showDialog<bool>(
        context: context,
        builder: (ctx) {
          return AlertDialog(
            title: const Text('Allow exact alarms?'),
            content: const Text(
              'Exact alarms are off on this phone. Reminders can still work, but may be a few minutes late.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Use Anyway'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Enable Exact'),
              ),
            ],
          );
        },
      );

      if (choice != true) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Using inexact reminders. Alerts may be slightly delayed.',
            ),
          ),
        );
        return;
      }

      final granted = await NotificationService.I
          .requestExactAlarmsPermissionIfNeeded();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            granted
                ? 'Exact alarms enabled.'
                : 'Exact alarms still off. Using inexact reminders.',
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not check exact alarm permission.'),
        ),
      );
    }
  }
}

class _ScheduleViewerIdentity {
  const _ScheduleViewerIdentity({
    required this.uid,
    required this.name,
    required this.serial,
    required this.isAdmin,
  });

  final String uid;
  final String name;
  final String serial;
  final bool isAdmin;
}

class _OccCacheEntry {
  const _OccCacheEntry({required this.signature, required this.items});

  final String signature;
  final List<_Occ> items;
}

class _Occ {
  final String classId;
  final String courseCode;
  final String courseTitle;
  final DateTime start;
  final DateTime end;
  final bool isOnline;
  final String onlineBookingKey;

  _Occ({
    required this.classId,
    required this.courseCode,
    required this.courseTitle,
    required this.start,
    required this.end,
    required this.isOnline,
    required this.onlineBookingKey,
  });

  String get notificationClassId {
    if (!isOnline) return classId;
    return 'online:$onlineBookingKey';
  }
}

class _SessionLearner {
  const _SessionLearner({required this.uid, required this.name});

  final String uid;
  final String name;
}

class _SessionCard extends StatefulWidget {
  const _SessionCard({
    super.key,
    required this.palette,
    required this.o,
    required this.learners,
    required this.enabled,
    required this.isConflict,
    required this.learnerAvatarBuilder,
    required this.learnerMiniLoader,
    required this.onLearnerProfile,
    required this.onLearnerReport,
    required this.onLearnerGallery,
    required this.onToggle,
    required this.onAttendance,
    required this.onProgress,
    required this.onOpenOnline,
  });

  final AppPalette palette;
  final _Occ o;
  final List<_SessionLearner> learners;
  final bool enabled;
  final bool isConflict;
  final Widget Function({required String profilePhotoUrl, double size})
  learnerAvatarBuilder;
  final Future<Map<String, String>> Function(String uid) learnerMiniLoader;
  final ValueChanged<_SessionLearner> onLearnerProfile;
  final ValueChanged<_SessionLearner> onLearnerReport;
  final ValueChanged<_SessionLearner> onLearnerGallery;
  final VoidCallback onToggle;
  final VoidCallback onAttendance;
  final VoidCallback onProgress;
  final VoidCallback onOpenOnline;

  @override
  State<_SessionCard> createState() => _SessionCardState();
}

class _SessionCardState extends State<_SessionCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final o = widget.o;
    final learners = widget.learners;
    final palette = widget.palette;
    final enabled = widget.enabled;
    final isConflict = widget.isConflict;
    final now = DateTime.now();
    final bool isLive = now.isAfter(o.start) && now.isBefore(o.end);
    final bool isPast = now.isAfter(o.end);
    final bool isLiveOnline = isLive && o.isOnline;

    Color statusColor = enabled
        ? palette.accent
        : palette.text.withValues(alpha: 0.35);
    if (isConflict) statusColor = const Color(0xFFD32F2F);
    if (isLive) statusColor = const Color(0xFF1B5E20);
    if (isPast) statusColor = palette.text.withValues(alpha: 0.30);
    if (o.isOnline && !isPast && !isLive) statusColor = const Color(0xFFD32F2F);

    final Color bgColor = isLive
        ? const Color(0xFFF1FBF3)
        : isPast
        ? palette.soft.withValues(alpha: 0.35)
        : (o.isOnline
              ? const Color(0xFFFFF5F5)
              : (isConflict ? const Color(0xFFFFEBEE) : palette.cardBg));

    final Color borderColor = isLive
        ? const Color(0xFF9AD5AB)
        : isConflict
        ? const Color(0xFFD32F2F).withValues(alpha: 0.28)
        : (o.isOnline
              ? const Color(0xFFD32F2F).withValues(alpha: 0.25)
              : palette.border);

    final Color titleColor = isPast
        ? palette.text.withValues(alpha: 0.45)
        : palette.text;
    final Color timeColor = isPast
        ? palette.text.withValues(alpha: 0.45)
        : (isLive ? const Color(0xFF1B5E20) : palette.primary);
    final hasToggle = learners.isNotEmpty;

    return Opacity(
      opacity: isPast ? 0.78 : 1,
      child: Container(
        margin: const EdgeInsets.only(bottom: 9),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: borderColor),
          boxShadow: isLive
              ? [
                  BoxShadow(
                    color: const Color(0xFF1B5E20).withValues(alpha: 0.10),
                    blurRadius: 14,
                    offset: const Offset(0, 8),
                  ),
                ]
              : [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.03),
                    blurRadius: 10,
                    offset: const Offset(0, 5),
                  ),
                ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: IntrinsicHeight(
            child: Row(
              children: [
                Container(width: 6, color: statusColor),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              '${DateFormat('hh:mm a').format(o.start)} - ${DateFormat('hh:mm a').format(o.end)}',
                              style: TextStyle(
                                fontWeight: FontWeight.w900,
                                fontSize: 14,
                                color: timeColor,
                              ),
                            ),
                            const Spacer(),
                            if (isLive) _LiveBadge(isOnline: isLiveOnline),
                            if (o.isOnline && !isLive)
                              Container(
                                margin: const EdgeInsets.only(left: 8),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFFDE8E8),
                                  borderRadius: BorderRadius.circular(999),
                                  border: Border.all(
                                    color: const Color(0xFFE8B7B7),
                                  ),
                                ),
                                child: const Text(
                                  'ONLINE',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w900,
                                    color: Color(0xFFB71C1C),
                                  ),
                                ),
                              ),
                            if (isPast)
                              Text(
                                'FINISHED',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w900,
                                  color: palette.text.withValues(alpha: 0.45),
                                ),
                              ),
                            if (isConflict)
                              const Padding(
                                padding: EdgeInsets.only(left: 8),
                                child: Icon(
                                  Icons.warning_rounded,
                                  color: Color(0xFFD32F2F),
                                  size: 20,
                                ),
                              ),
                            if (!isPast && !o.isOnline)
                              IconButton(
                                constraints: const BoxConstraints(),
                                padding: const EdgeInsets.only(left: 8),
                                icon: Icon(
                                  enabled
                                      ? Icons.notifications_active_rounded
                                      : Icons.notifications_off_outlined,
                                  color: enabled
                                      ? palette.accent
                                      : palette.text.withValues(alpha: 0.45),
                                  size: 20,
                                ),
                                onPressed: widget.onToggle,
                              ),
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(
                          o.courseTitle.isEmpty
                              ? 'Untitled Class'
                              : o.courseTitle,
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 14,
                            color: titleColor,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${o.courseCode} • ID: ${o.classId}',
                          style: TextStyle(
                            color: palette.text.withValues(alpha: 0.62),
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 7),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [if (isConflict) const _ConflictPill()],
                        ),
                        if (learners.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                            decoration: BoxDecoration(
                              color: palette.soft.withValues(alpha: 0.35),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: palette.border.withValues(alpha: 0.85),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        'Learners (${learners.length})',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w900,
                                          color: palette.primary,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ),
                                    if (hasToggle)
                                      IconButton(
                                        onPressed: () {
                                          setState(
                                            () => _expanded = !_expanded,
                                          );
                                        },
                                        visualDensity: VisualDensity.compact,
                                        tooltip: _expanded
                                            ? 'Collapse learners'
                                            : 'Show all learners',
                                        icon: AnimatedRotation(
                                          turns: _expanded ? 0.5 : 0,
                                          duration: const Duration(
                                            milliseconds: 180,
                                          ),
                                          child: Icon(
                                            Icons.keyboard_arrow_down_rounded,
                                            color: palette.primary,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                                TweenAnimationBuilder<double>(
                                  tween: Tween<double>(
                                    begin: 0,
                                    end: _expanded ? 1 : 0,
                                  ),
                                  duration: const Duration(milliseconds: 220),
                                  curve: Curves.easeOutCubic,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      ...learners.map((learner) {
                                        return FutureBuilder<
                                          Map<String, String>
                                        >(
                                          future: widget.learnerMiniLoader(
                                            learner.uid,
                                          ),
                                          builder: (context, snap) {
                                            final full =
                                                (snap.data?['full'] ?? '')
                                                    .trim();
                                            final displayName = full.isEmpty
                                                ? (learner.name.trim().isEmpty
                                                      ? 'Learner'
                                                      : learner.name)
                                                : full;
                                            final profilePhotoUrl =
                                                (snap.data?['profilePhoto'] ??
                                                        '')
                                                    .trim();
                                            final isExam =
                                                (snap.data?['examMode'] ?? '')
                                                        .toString() ==
                                                    'true';

                                            return Container(
                                              margin: const EdgeInsets.only(
                                                top: 6,
                                              ),
                                              padding: const EdgeInsets.all(8),
                                              decoration: BoxDecoration(
                                                color: isExam
                                                    ? Colors.purple
                                                        .withValues(alpha: 0.03)
                                                    : palette.cardBg,
                                                borderRadius:
                                                    BorderRadius.circular(10),
                                                border: Border.all(
                                                  color: isExam
                                                      ? Colors.purple
                                                          .withValues(alpha: 0.3)
                                                      : palette.border
                                                          .withValues(
                                                              alpha: 0.82),
                                                ),
                                              ),
                                              child: Column(
                                                children: [
                                                  Row(
                                                    children: [
                                                      widget
                                                          .learnerAvatarBuilder(
                                                            profilePhotoUrl:
                                                                profilePhotoUrl,
                                                            size: 28,
                                                          ),
                                                      const SizedBox(width: 8),
                                                      Expanded(
                                                        child: Text(
                                                          displayName,
                                                          maxLines: 1,
                                                          overflow: TextOverflow
                                                              .ellipsis,
                                                          style: TextStyle(
                                                            color: isExam
                                                                ? Colors.purple
                                                                : palette.text,
                                                            fontWeight:
                                                                FontWeight.w800,
                                                            fontSize: 12,
                                                          ),
                                                        ),
                                                      ),
                                                      if (isExam)
                                                        Container(
                                                          padding:
                                                              const EdgeInsets
                                                                  .symmetric(
                                                            horizontal: 6,
                                                            vertical: 2,
                                                          ),
                                                          decoration:
                                                              BoxDecoration(
                                                            color: Colors.purple
                                                                .withValues(
                                                                    alpha:
                                                                        0.1),
                                                            borderRadius:
                                                                BorderRadius
                                                                    .circular(
                                                                        6),
                                                          ),
                                                          child: const Text(
                                                            'Exam',
                                                            style: TextStyle(
                                                              color:
                                                                  Colors.purple,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w900,
                                                              fontSize: 10,
                                                            ),
                                                          ),
                                                        ),
                                                    ],
                                                  ),
                                                  if (!o.isOnline)
                                                    Padding(
                                                      padding:
                                                          const EdgeInsets.only(
                                                            top: 8,
                                                          ),
                                                      child: Row(
                                                        children: [
                                                          Expanded(
                                                            child: OutlinedButton(
                                                              onPressed: () =>
                                                                  widget
                                                                      .onLearnerProfile(
                                                                        learner,
                                                                      ),
                                                              child: const Text(
                                                                'Profile',
                                                              ),
                                                            ),
                                                          ),
                                                          const SizedBox(
                                                            width: 6,
                                                          ),
                                                          Expanded(
                                                            child: OutlinedButton(
                                                              onPressed: () =>
                                                                  widget
                                                                      .onLearnerReport(
                                                                        learner,
                                                                      ),
                                                              child: const Text(
                                                                'Report',
                                                              ),
                                                            ),
                                                          ),
                                                          const SizedBox(
                                                            width: 6,
                                                          ),
                                                          Expanded(
                                                            child: OutlinedButton(
                                                              onPressed: () =>
                                                                  widget
                                                                      .onLearnerGallery(
                                                                        learner,
                                                                      ),
                                                              child: const Text(
                                                                'Gallery',
                                                              ),
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                    ),
                                                ],
                                              ),
                                            );
                                          },
                                        );
                                      }),
                                    ],
                                  ),
                                  builder: (context, factor, child) {
                                    return ClipRect(
                                      child: Align(
                                        alignment: Alignment.topCenter,
                                        heightFactor: factor,
                                        child: IgnorePointer(
                                          ignoring: factor < 0.95,
                                          child: child,
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ],
                            ),
                          ),
                        ],
                        Divider(
                          height: 14,
                          color: palette.border.withValues(alpha: 0.9),
                        ),
                        Row(
                          children: [
                            Expanded(
                              child: _ActionButton(
                                label: o.isOnline
                                    ? 'Open Online Tab'
                                    : (isPast
                                          ? 'Update Attendance'
                                          : 'Take Attendance'),
                                icon: o.isOnline
                                    ? Icons.open_in_new_rounded
                                    : (isPast
                                          ? Icons.edit_note_rounded
                                          : Icons.how_to_reg_rounded),
                                color: o.isOnline
                                    ? const Color(0xFFB71C1C)
                                    : (isPast
                                          ? palette.text.withValues(alpha: 0.55)
                                          : palette.primary),
                                onTap: o.isOnline
                                    ? widget.onOpenOnline
                                    : widget.onAttendance,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: _ActionButton(
                                label: o.isOnline ? 'View Online' : 'Progress',
                                icon: o.isOnline
                                    ? Icons.wifi_tethering_rounded
                                    : Icons.insights_rounded,
                                color: o.isOnline
                                    ? const Color(0xFFD32F2F)
                                    : palette.text.withValues(alpha: 0.72),
                                onTap: o.isOnline
                                    ? widget.onOpenOnline
                                    : widget.onProgress,
                              ),
                            ),
                          ],
                        ),
                      ],
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
}

class _ConflictPill extends StatelessWidget {
  const _ConflictPill();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xFFFFEBEE),
        borderRadius: BorderRadius.circular(999),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.warning_rounded, size: 14, color: Color(0xFFD32F2F)),
          SizedBox(width: 6),
          Text(
            'Conflict detected',
            style: TextStyle(
              color: Color(0xFFD32F2F),
              fontWeight: FontWeight.w800,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

class _LiveBadge extends StatelessWidget {
  const _LiveBadge({required this.isOnline});

  final bool isOnline;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: isOnline ? const Color(0xFF1B5E20) : const Color(0xFF0D3B66),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Row(
        children: [
          Icon(Icons.circle, color: Colors.red, size: 8),
          SizedBox(width: 4),
          Text(
            'LIVE NOW',
            style: TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        decoration: BoxDecoration(
          border: Border.all(color: color.withValues(alpha: 0.20)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.palette,
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final AppPalette palette;
  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(26),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: palette.cardBg,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: palette.border),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 62,
                height: 62,
                decoration: BoxDecoration(
                  color: palette.soft,
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: palette.primary, size: 30),
              ),
              const SizedBox(height: 14),
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: palette.primary,
                  fontWeight: FontWeight.w900,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: palette.text.withValues(alpha: 0.68),
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
