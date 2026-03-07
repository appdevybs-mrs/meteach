// TeacherSchedule.dart
// Drop-in replacement with:
// ✅ Shows ONLY logged-in teacher schedule (by instructor_current.uid)
// ✅ Admin can still see ALL classes (role == "admin" from /users/{uid}/role)
// ✅ Settings tab removed; Settings is now a ⚙️ gear button (top-right) that opens a bottom sheet
// ✅ No new dependencies added.

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
import 'attendance_history_screen.dart';
import 'take_attendance_screen.dart';

class TeacherSchedule extends StatefulWidget {
  const TeacherSchedule({super.key});

  @override
  State<TeacherSchedule> createState() => _TeacherScheduleState();
}

class _TeacherScheduleState extends State<TeacherSchedule> {
  static const primaryBlue = Color(0xFF1A2B48);
  static const actionOrange = Color(0xFFF98D28);
  static const errorRed = Color(0xFFD32F2F);
  static const appBg = Color(0xFFF4F7F9);
  static const cardBorder = Color(0xFFE0E6ED);

  final DatabaseReference _classesRef =
  FirebaseDatabase.instance.ref().child('classes');

  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;

  bool _dailyEnabled = false;
  bool _sessionEnabled = false;

  late SharedPreferences _prefs;
  bool _prefsReady = false;

  bool _didAutoApply = false;

  // Keep latest computed lists so the gear button can open Settings safely.
  List<_Occ> _latestUpcoming = const [];
  List<_Occ> _latestAllOcc = const [];

  // Debounce / concurrency guards for scheduling
  Timer? _applyDebounce;
  bool _applyInProgress = false;
  bool _applyPending = false;
  List<_Occ> _lastUpcoming = const [];
  List<_Occ> _lastAllOcc = const [];

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void dispose() {
    _applyDebounce?.cancel();
    super.dispose();
  }

  Future<void> _boot() async {
    await NotificationService.I.init();
    await NotificationService.I.requestPermissions();

    _prefs = await SharedPreferences.getInstance();
    if (!mounted) return;

    setState(() {
      _dailyEnabled = _prefs.getBool('reminders_daily_enabled') ?? false;
      _sessionEnabled = _prefs.getBool('reminders_session_enabled') ?? false;
      _prefsReady = true;
    });
  }

  void _openSettingsSheet() {
    // If data isn't ready yet, do nothing (prevents crashes).
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
                decoration: const BoxDecoration(
                  color: appBg,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
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
        title: const Text("Important: Enable No Restrictions"),
        content: const Text(
          "To make class reminders work even when the app is closed, please set Battery to 'No restrictions' for this app.\n\n"
              "Tap Open Settings → then choose: Battery → No restrictions.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Later"),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(context);

              const intent = AndroidIntent(
                action: 'android.settings.APPLICATION_DETAILS_SETTINGS',
                data: 'package:com.dreamenglish.academy.dream_english_academy',
              );
              await intent.launch();
            },
            child: const Text("Open App Settings"),
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
      if (current.start.isBefore(other.end) && other.start.isBefore(current.end)) {
        return true;
      }
    }
    return false;
  }

  // Debounced apply to avoid cancel/reschedule storms when user toggles quickly.
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
      final allOcc = _lastAllOcc;

      debugPrint(
        'APPLY reminders: daily=$_dailyEnabled session=$_sessionEnabled upcoming=${upcoming.length} all=${allOcc.length}',
      );

      await NotificationService.I.cancelAll();
      debugPrint('Canceled all notifications');

      if (_dailyEnabled) {
        debugPrint('Scheduling daily reminder 08:00');
        await NotificationService.I.scheduleDailyReminder(
          hour: 8,
          minute: 0,
          title: 'Classes Today',
          body: 'Open app to see today\'s schedule.',
        );
      }

      if (_sessionEnabled) {
        debugPrint('Scheduling session reminders...');
        final filtered = upcoming
            .where((e) => _isClassEnabled(e.classId))
            .where((e) => _isDayEnabled(e.start))
            .where((e) => e.start.isAfter(DateTime.now()))
            .take(30);

        for (final o in filtered) {
          await NotificationService.I.scheduleSessionReminder(
            classId: o.classId,
            title: 'Class Starting',
            body: '${o.courseCode} at ${DateFormat('hh:mm a').format(o.start)}',
            sessionStart: o.start,
            minutesBefore: 15,
          );
        }
      }
    } catch (e, st) {
      debugPrint('ERROR applying reminders: $e\n$st');
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
    return DefaultTabController(
      length: 2, // ✅ only Schedule + Calendar now
      child: Scaffold(
        backgroundColor: appBg,
        appBar: AppBar(
          backgroundColor: Colors.white,
          elevation: 0,
          title: const Text(
            'Teacher Schedule',
            style: TextStyle(color: primaryBlue, fontWeight: FontWeight.w900),
          ),
          actions: [
            IconButton(
              tooltip: 'Settings',
              icon: const Icon(Icons.settings_rounded, color: primaryBlue),
              onPressed: _openSettingsSheet,
            ),
          ],
          bottom: const TabBar(
            labelColor: primaryBlue,
            indicatorColor: actionOrange,
            tabs: [
              Tab(text: 'Schedule', icon: Icon(Icons.format_list_bulleted_rounded)),
              Tab(text: 'Calendar', icon: Icon(Icons.calendar_month_rounded)),
            ],
          ),
        ),
        body: StreamBuilder<DatabaseEvent>(
          stream: _classesRef.onValue,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting || !_prefsReady) {
              return const Center(child: CircularProgressIndicator());
            }

            final data = snap.data?.snapshot.value;
            if (data == null) {
              return const Center(child: Text('No classes found.'));
            }

            // Safely parse RTDB data
            final rawClasses = <Map<String, dynamic>>[];
            if (data is Map) {
              for (final v in data.values) {
                if (v is Map) {
                  rawClasses.add(Map<String, dynamic>.from(v));
                }
              }
            }

            if (rawClasses.isEmpty) {
              return const Center(child: Text('No classes found.'));
            }

            // ✅ Logged-in uid
            final currentUser = FirebaseAuth.instance.currentUser;
            final myUid = currentUser?.uid;

            if (myUid == null || myUid.isEmpty) {
              return const Center(
                child: Text('No logged-in user found. Please log out and log in again.'),
              );
            }

            // ✅ Admin override: role from /users/{uid}/role
            final roleRef = FirebaseDatabase.instance.ref('users/$myUid/role');

            return FutureBuilder<DataSnapshot>(
              future: roleRef.get(),
              builder: (context, roleSnap) {
                if (!roleSnap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }

                final role = (roleSnap.data?.value ?? '').toString().toLowerCase().trim();
                final isAdmin = role == 'admin';

                // ✅ Teacher filter: class.instructor_current.uid == myUid
                final teacherOnlyClasses = rawClasses.where((c) {
                  final instructorCurrent = c['instructor_current'];
                  if (instructorCurrent is Map) {
                    final ic = Map<String, dynamic>.from(instructorCurrent);
                    final uid = ic['uid']?.toString();
                    return uid == myUid;
                  }
                  return false;
                }).toList();

                final visibleClasses = isAdmin ? rawClasses : teacherOnlyClasses;

                if (!isAdmin && visibleClasses.isEmpty) {
                  return const Center(
                    child: Text('No classes assigned to this teacher.'),
                  );
                }

                final allOcc = <_Occ>[];
                for (final cls in visibleClasses) {
                  allOcc.addAll(_generateOccurrences(cls));
                }
                allOcc.sort((a, b) => a.start.compareTo(b.start));

                final now = DateTime.now();
                final twoDaysAgo = now.subtract(const Duration(days: 2));
                final recentAndUpcoming =
                allOcc.where((o) => o.end.isAfter(twoDaysAgo)).toList();

                // Save latest lists for Settings gear usage
                _latestAllOcc = allOcc;
                _latestUpcoming = recentAndUpcoming;

                // Auto reschedule once after first data load
                if (_prefsReady && !_didAutoApply) {
                  _didAutoApply = true;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!mounted) return;
                    _queueApplyAllReminders(upcoming: recentAndUpcoming, allOcc: allOcc);
                  });
                }

                return TabBarView(
                  children: [
                    _buildGroupedSchedule(recentAndUpcoming, allOcc, visibleClasses),
                    _buildCalendarView(allOcc, recentAndUpcoming, visibleClasses),
                  ],
                );
              },
            );
          },
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
      return const Center(child: Text('No recent or upcoming classes.'));
    }

    final Map<String, List<_Occ>> grouped = {};
    for (final o in displayList) {
      final header = _fmtDayHeader(o.start);
      grouped.putIfAbsent(header, () => []).add(o);
    }
    final headers = grouped.keys.toList();

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: headers.length,
      itemBuilder: (context, index) {
        final day = headers[index];
        final dayClasses = grouped[day]!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
              child: Text(
                day,
                style: const TextStyle(
                  color: primaryBlue,
                  fontWeight: FontWeight.w800,
                  fontSize: 15,
                ),
              ),
            ),
            ...dayClasses.map((o) {
              final isConflict = _hasConflict(o, dayClasses);
              return _SessionCard(
                o: o,
                isConflict: isConflict,
                enabled: _isClassEnabled(o.classId),
                onToggle: () => _toggleClassNotif(o.classId, displayList, allOcc),
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
        TableCalendar(
          firstDay: DateTime.now().subtract(const Duration(days: 365)),
          lastDay: DateTime.now().add(const Duration(days: 365)),
          focusedDay: _focusedDay,
          selectedDayPredicate: (day) => isSameDay(selected, day),
          calendarFormat: CalendarFormat.month,
          headerStyle: const HeaderStyle(formatButtonVisible: false, titleCentered: true),
          calendarStyle: const CalendarStyle(
            selectedDecoration: BoxDecoration(color: primaryBlue, shape: BoxShape.circle),
            markerDecoration: BoxDecoration(color: actionOrange, shape: BoxShape.circle),
          ),
          onDaySelected: (s, f) => setState(() {
            _selectedDay = s;
            _focusedDay = f;
          }),
          eventLoader: (day) => byDay[_fmtKey(day)] ?? const [],
        ),
        const Divider(height: 1),

        Padding(
          padding: const EdgeInsets.all(12),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: cardBorder),
            ),
            child: SwitchListTile(
              title: Text("Reminders for ${DateFormat('yyyy-MM-dd').format(selected)}"),
              subtitle: const Text("Disable = no reminders for all classes on this date"),
              value: _isDayEnabled(selected),
              onChanged: (v) => _toggleDay(selected, v, upcoming, allOcc),
              secondary: Icon(
                _isDayEnabled(selected)
                    ? Icons.notifications_active_rounded
                    : Icons.notifications_off_rounded,
                color: _isDayEnabled(selected) ? actionOrange : Colors.grey,
              ),
            ),
          ),
        ),

        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: events.length,
            itemBuilder: (context, i) {
              final isConflict = _hasConflict(events[i], events);
              return _SessionCard(
                o: events[i],
                isConflict: isConflict,
                enabled: _isClassEnabled(events[i].classId),
                onToggle: () => _toggleClassNotif(events[i].classId, upcoming, allOcc),
                onAttendance: () => _openAttendance(events[i], visibleClasses),
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
      MaterialPageRoute(builder: (_) => TakeAttendanceScreen(classData: classMap)),
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
      MaterialPageRoute(builder: (_) => AttendanceHistoryScreen(classData: classMap)),
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
            const Expanded(
              child: Text(
                "Notifications",
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: primaryBlue),
              ),
            ),
            IconButton(
              tooltip: 'Close',
              icon: const Icon(Icons.close_rounded),
              onPressed: () => Navigator.pop(context),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: cardBorder),
          ),
          child: Column(
            children: [
              SwitchListTile(
                secondary: const Icon(Icons.wb_sunny_rounded, color: actionOrange),
                title: const Text("Daily Briefing (8:00 AM)"),
                value: _dailyEnabled,
                onChanged: (v) async {
                  await _toggleDaily(v, upcoming, allOcc);
                  onSheetRefresh?.call();
                },
              ),
              const Divider(height: 1, indent: 50),
              SwitchListTile(
                secondary: const Icon(Icons.notifications_active_rounded, color: primaryBlue),
                title: const Text("Session Alerts (15m before)"),
                value: _sessionEnabled,
                onChanged: (v) async {
                  await _toggleDaily(v, upcoming, allOcc);
                  onSheetRefresh?.call();
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  // Safer occurrence generator: handles malformed data and sessions_count edge cases.
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
    if (sessionsRaw is! List) return [];

    final pattern = sessionsRaw
        .whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m))
        .toList();
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
        final hh = (parts.isNotEmpty) ? int.tryParse(parts[0]) : null;
        final mm = (parts.length >= 2) ? int.tryParse(parts[1]) : null;

        final startHour = (hh != null && hh >= 0 && hh <= 23) ? hh : 0;
        final startMin = (mm != null && mm >= 0 && mm <= 59) ? mm : 0;

        final start = DateTime(sDate.year, sDate.month, sDate.day, startHour, startMin);

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
    const days = {
      'Mon': 1,
      'Tue': 2,
      'Wed': 3,
      'Thu': 4,
      'Fri': 5,
      'Sat': 6,
      'Sun': 7
    };
    return days[day] ?? 1;
  }

  Future<void> _toggleClassNotif(String classId, List<_Occ> up, List<_Occ> all) async {
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

class _Occ {
  final String classId, courseCode, courseTitle;
  final DateTime start, end;

  _Occ({
    required this.classId,
    required this.courseCode,
    required this.courseTitle,
    required this.start,
    required this.end,
  });
}

class _SessionCard extends StatelessWidget {
  final _Occ o;
  final bool enabled;
  final bool isConflict;
  final VoidCallback onToggle;
  final VoidCallback onAttendance;
  final VoidCallback onHistory;

  const _SessionCard({
    required this.o,
    required this.enabled,
    required this.isConflict,
    required this.onToggle,
    required this.onAttendance,
    required this.onHistory,
  });

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final bool isLive = now.isAfter(o.start) && now.isBefore(o.end);
    final bool isPast = now.isAfter(o.end);

    Color statusColor = enabled ? const Color(0xFFF98D28) : Colors.grey.shade400;
    if (isConflict) statusColor = const Color(0xFFD32F2F);
    if (isLive) statusColor = const Color(0xFF1A2B48);
    if (isPast) statusColor = Colors.grey.shade400;

    return Opacity(
      opacity: isPast ? 0.7 : 1.0,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: isPast ? Colors.grey.shade50 : (isConflict ? const Color(0xFFFFEBEE) : Colors.white),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isConflict ? const Color(0xFFD32F2F).withOpacity(0.3) : const Color(0xFFE0E6ED),
          ),
          boxShadow: isLive
              ? [
            BoxShadow(
              color: const Color(0xFF1A2B48).withOpacity(0.1),
              blurRadius: 8,
              offset: const Offset(0, 4),
            )
          ]
              : null,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
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
                                fontSize: 16,
                                color: isPast
                                    ? Colors.grey
                                    : (isLive ? const Color(0xFF1A2B48) : const Color(0xFF2D2D2D)),
                              ),
                            ),
                            const Spacer(),
                            if (isLive) _LiveBadge(),
                            if (isPast)
                              const Text(
                                'FINISHED',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.grey,
                                ),
                              ),
                            if (isConflict)
                              const Icon(Icons.warning_rounded, color: Color(0xFFD32F2F), size: 20),
                            if (!isPast)
                              IconButton(
                                constraints: const BoxConstraints(),
                                padding: const EdgeInsets.only(left: 8),
                                icon: Icon(
                                  enabled ? Icons.notifications_active : Icons.notifications_off_outlined,
                                  color: enabled ? const Color(0xFFF98D28) : Colors.grey,
                                  size: 20,
                                ),
                                onPressed: onToggle,
                              )
                          ],
                        ),
                        Text(
                          o.courseTitle,
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                            color: isPast ? Colors.grey : Colors.black,
                          ),
                        ),
                        Text(
                          '${o.courseCode} • ID: ${o.classId}',
                          style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                        ),
                        const Divider(height: 20),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            _ActionButton(
                              label: isPast ? 'Update Attendance' : 'Take Attendance',
                              icon: isPast ? Icons.edit_note_rounded : Icons.how_to_reg_rounded,
                              color: isPast ? Colors.grey : const Color(0xFF1A2B48),
                              onTap: onAttendance,
                            ),
                            const SizedBox(width: 8),
                            _ActionButton(
                              label: 'History',
                              icon: Icons.history_rounded,
                              color: Colors.grey.shade700,
                              onTap: onHistory,
                            ),
                          ],
                        )
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

class _LiveBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF1A2B48),
        borderRadius: BorderRadius.circular(6),
      ),
      child: const Row(
        children: [
          Icon(Icons.circle, color: Colors.red, size: 8),
          SizedBox(width: 4),
          Text(
            'LIVE NOW',
            style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _ActionButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            border: Border.all(color: color.withOpacity(0.2)),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
