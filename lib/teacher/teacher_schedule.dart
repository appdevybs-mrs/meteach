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
import '../shared/app_theme.dart';
import '../shared/teacher_tour_guide.dart';
import '../shared/teacher_web_layout.dart';
import 'attendance_history_screen.dart';
import 'take_attendance_screen.dart';

class TeacherSchedule extends StatefulWidget {
  const TeacherSchedule({super.key});

  @override
  State<TeacherSchedule> createState() => _TeacherScheduleState();
}

class _TeacherScheduleState extends State<TeacherSchedule> {
  final DatabaseReference _classesRef = FirebaseDatabase.instance.ref().child(
    'classes',
  );

  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;

  bool _dailyEnabled = false;
  bool _sessionEnabled = false;

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

  bool _viewerReady = false;
  bool _isAdminViewer = false;
  String _viewerUid = '';
  String _viewerName = '';
  String _viewerSerial = '';

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

  Future<void> _boot() async {
    await NotificationService.I.init();
    await NotificationService.I.requestPermissions();

    _prefs = await SharedPreferences.getInstance();
    final viewer = await _loadViewerIdentity();
    if (!mounted) return;

    setState(() {
      _dailyEnabled = _prefs.getBool('reminders_daily_enabled') ?? false;
      _sessionEnabled = _prefs.getBool('reminders_session_enabled') ?? false;
      _prefsReady = true;
      _viewerUid = viewer.uid;
      _viewerName = viewer.name;
      _viewerSerial = viewer.serial;
      _isAdminViewer = viewer.isAdmin;
      _viewerReady = true;
    });
  }

  Future<_ScheduleViewerIdentity> _loadViewerIdentity() async {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (uid.isEmpty) {
      return const _ScheduleViewerIdentity(
        uid: '',
        name: '',
        serial: '',
        isAdmin: false,
      );
    }

    try {
      final snap = await FirebaseDatabase.instance.ref('users/$uid').get();
      if (!snap.exists || snap.value is! Map) {
        return _ScheduleViewerIdentity(
          uid: uid,
          name: '',
          serial: '',
          isAdmin: false,
        );
      }

      final m = Map<String, dynamic>.from(snap.value as Map);
      final fn = (m['first_name'] ?? '').toString().trim();
      final ln = (m['last_name'] ?? '').toString().trim();
      final role = (m['role'] ?? '').toString().trim().toLowerCase();

      return _ScheduleViewerIdentity(
        uid: uid,
        name: ('$fn $ln').trim(),
        serial: (m['serial'] ?? '').toString().trim(),
        isAdmin: role == 'admin',
      );
    } catch (_) {
      return _ScheduleViewerIdentity(
        uid: uid,
        name: '',
        serial: '',
        isAdmin: false,
      );
    }
  }

  String _norm(String s) => s.trim().toLowerCase();

  bool _matchesTeacherClass(Map<String, dynamic> classData) {
    String curUid = '';
    String curName = '';

    final cur = classData['instructor_current'];
    if (cur is Map) {
      final curMap = Map<String, dynamic>.from(cur);
      curUid = (curMap['uid'] ?? '').toString().trim();
      curName = (curMap['name'] ?? '').toString().trim();
    }

    final legacyInstructorName = (classData['instructor'] ?? '')
        .toString()
        .trim();

    final matchesUid = curUid.isNotEmpty && curUid == _viewerUid;

    final matchesName =
        _viewerName.isNotEmpty &&
        _norm(
              legacyInstructorName.isNotEmpty ? legacyInstructorName : curName,
            ) ==
            _norm(_viewerName);

    final legacySerial =
        (classData['instructorserial'] ?? classData['serial'] ?? '')
            .toString()
            .trim();
    final matchesSerial =
        _viewerSerial.isNotEmpty && legacySerial == _viewerSerial;

    return matchesUid || matchesName || matchesSerial;
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
        .where((e) => _isClassEnabled(e.classId))
        .where((e) => _isDayEnabled(e.start))
        .where((e) => e.start.isAfter(now))
        .take(maxToSchedule)
        .toList();
  }

  String _reminderPlanKey(List<_Occ> candidates) {
    final sb = StringBuffer()
      ..write('d:')
      ..write(_dailyEnabled ? '1' : '0')
      ..write(';s:')
      ..write(_sessionEnabled ? '1' : '0')
      ..write(';');
    for (final o in candidates) {
      sb
        ..write(o.classId)
        ..write('@')
        ..write(o.start.millisecondsSinceEpoch)
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
                data: 'package:com.dreamenglish.academy.dream_english_academy',
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

  Future<void> _toggleDay(
    DateTime day,
    bool enabled,
    List<_Occ> up,
    List<_Occ> all,
  ) async {
    if (!_prefsReady) return;
    final key = 'remind_day_${_fmtKey(day)}';
    await _prefs.setBool(key, enabled);
    if (mounted) setState(() {});
    _queueApplyAllReminders(upcoming: up, allOcc: all);
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
      final planKey = _reminderPlanKey(reminderCandidates);
      if (planKey == _lastAppliedReminderPlanKey) {
        return;
      }

      await NotificationService.I.cancelAll();

      if (_dailyEnabled) {
        await NotificationService.I.scheduleDailyReminder(
          hour: 8,
          minute: 0,
          title: 'Classes Today',
          body: 'Open app to see today\'s schedule.',
        );
      }

      if (_sessionEnabled) {
        for (final o in reminderCandidates) {
          await NotificationService.I.scheduleSessionReminder(
            classId: o.classId,
            title: 'Class Starting',
            body: '${o.courseCode} at ${DateFormat('hh:mm a').format(o.start)}',
            sessionStart: o.start,
            minutesBefore: 15,
          );
        }
      }
      _lastAppliedReminderPlanKey = planKey;
    } catch (_) {
    } finally {
      _applyInProgress = false;
      if (_applyPending) {
        _applyPending = false;
        await _applyAllRemindersInternal();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    TeacherTourGuide.schedule(
      context,
      screenId: 'teacher_schedule',
      hints: const [
        TeacherTourHint(
          title: 'Schedule overview',
          line: 'Track upcoming classes and open attendance from this page.',
        ),
        TeacherTourHint(
          title: 'Calendar and settings',
          line:
              'Use calendar tabs and settings to manage reminders and visibility.',
        ),
      ],
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

              if (!isAdmin && visibleClasses.isEmpty) {
                return _EmptyState(
                  palette: p,
                  icon: Icons.groups_rounded,
                  title: 'No classes assigned',
                  subtitle: 'No classes are assigned to this teacher yet.',
                );
              }

              final allOcc = <_Occ>[];
              for (final cls in visibleClasses) {
                allOcc.addAll(_occurrencesForClassCached(cls));
              }
              allOcc.sort((a, b) => a.start.compareTo(b.start));

              final now = DateTime.now();
              final twoDaysAgo = now.subtract(const Duration(days: 2));
              final recentAndUpcoming = allOcc
                  .where((o) => o.end.isAfter(twoDaysAgo))
                  .toList();

              _latestAllOcc = allOcc;
              _latestUpcoming = recentAndUpcoming;

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

              return Column(
                children: [
                  _ScheduleTopSummary(
                    palette: p,
                    totalClasses: visibleClasses.length,
                    totalSessions: recentAndUpcoming.length,
                    remindersOn: _sessionEnabled || _dailyEnabled,
                    isAdmin: isAdmin,
                  ),
                  Expanded(
                    child: TabBarView(
                      children: [
                        _buildGroupedSchedule(
                          recentAndUpcoming,
                          allOcc,
                          visibleClasses,
                        ),
                        _buildCalendarView(
                          allOcc,
                          recentAndUpcoming,
                          visibleClasses,
                        ),
                      ],
                    ),
                  ),
                ],
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
                palette: p,
                o: o,
                isConflict: isConflict,
                enabled: _isClassEnabled(o.classId),
                onToggle: () =>
                    _toggleClassNotif(o.classId, displayList, allOcc),
                onAttendance: () => _openAttendance(o, visibleClasses),
                onHistory: () => _openHistory(o, visibleClasses),
              );
            }),
          ],
        );
      },
    );
  }

  Widget _buildCalendarView(
    List<_Occ> allOcc,
    List<_Occ> upcoming,
    List<Map<String, dynamic>> visibleClasses,
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
        Container(
          margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          decoration: BoxDecoration(
            color: p.cardBg,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: p.border.withValues(alpha: 0.85)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.03),
                blurRadius: 14,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: TableCalendar(
            firstDay: DateTime.now().subtract(const Duration(days: 365)),
            lastDay: DateTime.now().add(const Duration(days: 365)),
            focusedDay: _focusedDay,
            selectedDayPredicate: (day) => isSameDay(selected, day),
            calendarFormat: CalendarFormat.month,
            headerStyle: HeaderStyle(
              formatButtonVisible: false,
              titleCentered: true,
              titleTextStyle: TextStyle(
                color: p.primary,
                fontWeight: FontWeight.w900,
                fontSize: 16,
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
              markerDecoration: BoxDecoration(
                color: p.accent,
                shape: BoxShape.circle,
              ),
              markersMaxCount: 3,
              outsideTextStyle: TextStyle(
                color: p.text.withValues(alpha: 0.35),
              ),
            ),
            onDaySelected: (s, f) => setState(() {
              _selectedDay = s;
              _focusedDay = f;
            }),
            eventLoader: (day) => byDay[_fmtKey(day)] ?? const [],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Container(
            decoration: BoxDecoration(
              color: p.cardBg,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: p.border),
            ),
            child: SwitchListTile(
              activeThumbColor: p.accent,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 4,
              ),
              title: Text(
                'Reminders for ${DateFormat('yyyy-MM-dd').format(selected)}',
                style: TextStyle(
                  color: p.primary,
                  fontWeight: FontWeight.w900,
                  fontSize: 14,
                ),
              ),
              subtitle: Text(
                'Disable = no reminders for all classes on this date',
                style: TextStyle(
                  color: p.text.withValues(alpha: 0.68),
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
              value: _isDayEnabled(selected),
              onChanged: (v) => _toggleDay(selected, v, upcoming, allOcc),
              secondary: Icon(
                _isDayEnabled(selected)
                    ? Icons.notifications_active_rounded
                    : Icons.notifications_off_rounded,
                color: _isDayEnabled(selected)
                    ? p.accent
                    : p.text.withValues(alpha: 0.45),
              ),
            ),
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
                      palette: p,
                      o: events[i],
                      isConflict: isConflict,
                      enabled: _isClassEnabled(events[i].classId),
                      onToggle: () => _toggleClassNotif(
                        events[i].classId,
                        upcoming,
                        allOcc,
                      ),
                      onAttendance: () =>
                          _openAttendance(events[i], visibleClasses),
                      onHistory: () => _openHistory(events[i], visibleClasses),
                    );
                  },
                ),
        ),
      ],
    );
  }

  void _openAttendance(_Occ o, List<Map<String, dynamic>> visibleClasses) {
    final classMap = visibleClasses.firstWhere(
      (c) => (c['class_id'] ?? c['id'])?.toString() == o.classId,
      orElse: () => <String, dynamic>{},
    );
    if (classMap.isEmpty) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TakeAttendanceScreen(classData: classMap),
      ),
    );
  }

  void _openHistory(_Occ o, List<Map<String, dynamic>> visibleClasses) {
    final classMap = visibleClasses.firstWhere(
      (c) => (c['class_id'] ?? c['id'])?.toString() == o.classId,
      orElse: () => <String, dynamic>{},
    );
    if (classMap.isEmpty) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AttendanceHistoryScreen(classData: classMap),
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
              SwitchListTile(
                activeThumbColor: p.accent,
                secondary: Icon(Icons.wb_sunny_rounded, color: p.accent),
                title: Text(
                  'Daily Briefing (8:00 AM)',
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
              Divider(height: 1, indent: 56, color: p.border),
              SwitchListTile(
                activeThumbColor: p.accent,
                secondary: Icon(
                  Icons.notifications_active_rounded,
                  color: p.primary,
                ),
                title: Text(
                  'Session Alerts (15m before)',
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
            ],
          ),
        ),
      ],
    );
  }

  List<_Occ> _generateOccurrences(Map<String, dynamic> cls) {
    if (cls['status']?.toString() != 'active') return [];

    final schedule = (cls['schedule'] is Map)
        ? Map<String, dynamic>.from(cls['schedule'])
        : null;
    if (schedule == null) return [];

    final firstDateRaw = schedule['first_session_date']?.toString() ?? '';
    final firstDate = DateTime.tryParse(firstDateRaw);
    if (firstDate == null) return [];

    final sessionsRaw = schedule['sessions'];
    final pattern = <Map<String, dynamic>>[];
    if (sessionsRaw is List) {
      for (final it in sessionsRaw) {
        if (it is! Map) continue;
        pattern.add(Map<String, dynamic>.from(it));
      }
    } else if (sessionsRaw is Map) {
      for (final it in sessionsRaw.values) {
        if (it is! Map) continue;
        pattern.add(Map<String, dynamic>.from(it));
      }
    }
    if (pattern.isEmpty) return [];

    final countLimitRaw = schedule['sessions_count']?.toString() ?? '';
    int countLimit = int.tryParse(countLimitRaw) ?? 0;
    if (countLimit <= 0) countLimit = 200;

    final classId = (cls['class_id'] ?? cls['id'] ?? '').toString();
    final courseCode = (cls['course_code'] ?? '').toString();
    final courseTitle = (cls['course_title'] ?? '').toString();

    final List<_Occ> occ = [];

    DateTime cursor = DateTime(firstDate.year, firstDate.month, firstDate.day);

    for (int week = 0; week < 52; week++) {
      for (final s in pattern) {
        if (occ.length >= countLimit) break;

        final dayShort = (s['day'] ?? 'Mon').toString();
        final targetWeekday = _weekdayFromShort(dayShort);

        int diff = targetWeekday - cursor.weekday;
        if (diff < 0) diff += 7;
        final sDate = cursor.add(Duration(days: diff));

        final startTimeStr = (s['start_time'] ?? '00:00').toString();
        final parts = startTimeStr.split(':');
        final hh = parts.isNotEmpty ? int.tryParse(parts[0]) : null;
        final mm = parts.length >= 2 ? int.tryParse(parts[1]) : null;

        final startHour = (hh != null && hh >= 0 && hh <= 23) ? hh : 0;
        final startMin = (mm != null && mm >= 0 && mm <= 59) ? mm : 0;

        final start = DateTime(
          sDate.year,
          sDate.month,
          sDate.day,
          startHour,
          startMin,
        );

        if (start.isBefore(firstDate)) continue;

        final durRaw = (s['duration_min'] ?? '60').toString();
        final dur = int.tryParse(durRaw);
        final durationMin = (dur != null && dur > 0) ? dur : 60;

        occ.add(
          _Occ(
            classId: classId,
            courseCode: courseCode,
            courseTitle: courseTitle,
            start: start,
            end: start.add(Duration(minutes: durationMin)),
          ),
        );
      }

      cursor = cursor.add(const Duration(days: 7));
      if (occ.length >= countLimit) break;
    }

    occ.sort((a, b) => a.start.compareTo(b.start));
    return occ;
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

  Future<void> _toggleClassNotif(
    String classId,
    List<_Occ> up,
    List<_Occ> all,
  ) async {
    if (!_prefsReady) return;

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
    }

    _queueApplyAllReminders(upcoming: up, allOcc: all);
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

  _Occ({
    required this.classId,
    required this.courseCode,
    required this.courseTitle,
    required this.start,
    required this.end,
  });
}

class _ScheduleTopSummary extends StatelessWidget {
  const _ScheduleTopSummary({
    required this.palette,
    required this.totalClasses,
    required this.totalSessions,
    required this.remindersOn,
    required this.isAdmin,
  });

  final AppPalette palette;
  final int totalClasses;
  final int totalSessions;
  final bool remindersOn;
  final bool isAdmin;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [palette.primary, palette.primary.withValues(alpha: 0.88)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
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
            isAdmin ? 'Admin view' : 'Teacher view',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.80),
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Your Schedule Overview',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w900,
              fontSize: 20,
              height: 1.1,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _HeroStat(label: 'Classes', value: '$totalClasses'),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _HeroStat(label: 'Sessions', value: '$totalSessions'),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _HeroStat(
                  label: 'Alerts',
                  value: remindersOn ? 'On' : 'Off',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HeroStat extends StatelessWidget {
  const _HeroStat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
      ),
      child: Column(
        children: [
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w900,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.80),
              fontWeight: FontWeight.w700,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

class _SessionCard extends StatelessWidget {
  const _SessionCard({
    required this.palette,
    required this.o,
    required this.enabled,
    required this.isConflict,
    required this.onToggle,
    required this.onAttendance,
    required this.onHistory,
  });

  final AppPalette palette;
  final _Occ o;
  final bool enabled;
  final bool isConflict;
  final VoidCallback onToggle;
  final VoidCallback onAttendance;
  final VoidCallback onHistory;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final bool isLive = now.isAfter(o.start) && now.isBefore(o.end);
    final bool isPast = now.isAfter(o.end);

    Color statusColor = enabled
        ? palette.accent
        : palette.text.withValues(alpha: 0.35);
    if (isConflict) statusColor = const Color(0xFFD32F2F);
    if (isLive) statusColor = palette.primary;
    if (isPast) statusColor = palette.text.withValues(alpha: 0.30);

    final Color bgColor = isPast
        ? palette.soft.withValues(alpha: 0.35)
        : (isConflict ? const Color(0xFFFFEBEE) : palette.cardBg);

    final Color borderColor = isConflict
        ? const Color(0xFFD32F2F).withValues(alpha: 0.28)
        : palette.border;

    final Color titleColor = isPast
        ? palette.text.withValues(alpha: 0.45)
        : palette.text;
    final Color timeColor = isPast
        ? palette.text.withValues(alpha: 0.45)
        : (isLive ? palette.primary : palette.primary);

    return Opacity(
      opacity: isPast ? 0.78 : 1,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: borderColor),
          boxShadow: isLive
              ? [
                  BoxShadow(
                    color: palette.primary.withValues(alpha: 0.10),
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
          borderRadius: BorderRadius.circular(20),
          child: IntrinsicHeight(
            child: Row(
              children: [
                Container(width: 6, color: statusColor),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              DateFormat('hh:mm a').format(o.start),
                              style: TextStyle(
                                fontWeight: FontWeight.w900,
                                fontSize: 17,
                                color: timeColor,
                              ),
                            ),
                            const Spacer(),
                            if (isLive) _LiveBadge(palette: palette),
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
                            if (!isPast)
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
                                onPressed: onToggle,
                              ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          o.courseTitle.isEmpty
                              ? 'Untitled Class'
                              : o.courseTitle,
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 15,
                            color: titleColor,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${o.courseCode} • ID: ${o.classId}',
                          style: TextStyle(
                            color: palette.text.withValues(alpha: 0.62),
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            _InfoPill(
                              palette: palette,
                              icon: Icons.schedule_rounded,
                              text:
                                  '${DateFormat('hh:mm a').format(o.start)} - ${DateFormat('hh:mm a').format(o.end)}',
                            ),
                            if (isConflict) const _ConflictPill(),
                          ],
                        ),
                        Divider(
                          height: 20,
                          color: palette.border.withValues(alpha: 0.9),
                        ),
                        Row(
                          children: [
                            Expanded(
                              child: _ActionButton(
                                label: isPast
                                    ? 'Update Attendance'
                                    : 'Take Attendance',
                                icon: isPast
                                    ? Icons.edit_note_rounded
                                    : Icons.how_to_reg_rounded,
                                color: isPast
                                    ? palette.text.withValues(alpha: 0.55)
                                    : palette.primary,
                                onTap: onAttendance,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: _ActionButton(
                                label: 'History',
                                icon: Icons.history_rounded,
                                color: palette.text.withValues(alpha: 0.72),
                                onTap: onHistory,
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

class _InfoPill extends StatelessWidget {
  const _InfoPill({
    required this.palette,
    required this.icon,
    required this.text,
  });

  final AppPalette palette;
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: palette.soft.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: palette.primary),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              color: palette.primary,
              fontWeight: FontWeight.w800,
              fontSize: 11,
            ),
          ),
        ],
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
  const _LiveBadge({required this.palette});

  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: palette.primary,
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
