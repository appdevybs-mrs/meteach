import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:table_calendar/table_calendar.dart';

import '../services/notification_service.dart';

class AdminScheduleScreen extends StatefulWidget {
  const AdminScheduleScreen({super.key});

  @override
  State<AdminScheduleScreen> createState() => _AdminScheduleScreenState();
}

class _AdminScheduleScreenState extends State<AdminScheduleScreen> {
  // ===== Brand colors (match your theme) =====
  static const primaryBlue = Color(0xFF1A2B48);
  static const actionOrange = Color(0xFFF98D28);
  static const mainText = Color(0xFF2D2D2D);
  static const appBg = Color(0xFFF4F7F9);

  final DatabaseReference _classesRef =
  FirebaseDatabase.instance.ref().child('classes');

  // View toggle
  int _mode = 0; // 0 = Upcoming, 1 = Calendar

  // Calendar state
  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;

  // Reminder settings (global)
  bool _dailyEnabled = false;   // "You have classes today"
  bool _sessionEnabled = false; // 15-min before each session

  // Fixed per your request
  int _minutesBefore = 15;

  // Daily reminder time (recommended)
  int _dailyHour = 8;
  int _dailyMinute = 0;

  // Pref keys
  static const _prefsDailyEnabled = 'reminders_daily_enabled';
  static const _prefsSessionEnabled = 'reminders_session_enabled';
  static const _prefsMinutesBefore = 'reminders_minutes_before';
  static const _prefsDailyHour = 'reminders_daily_hour';
  static const _prefsDailyMinute = 'reminders_daily_minute';

  // Per-class toggle key prefix
  static const _classRemindPrefix = 'remind_class_'; // + classId

  SharedPreferences? _prefs;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    await NotificationService.I.init();
    final p = await SharedPreferences.getInstance();

    if (!mounted) return;
    setState(() {
      _prefs = p;
      _dailyEnabled = p.getBool(_prefsDailyEnabled) ?? false;
      _sessionEnabled = p.getBool(_prefsSessionEnabled) ?? false;
      _minutesBefore = p.getInt(_prefsMinutesBefore) ?? 15;
      _dailyHour = p.getInt(_prefsDailyHour) ?? 8;
      _dailyMinute = p.getInt(_prefsDailyMinute) ?? 0;
    });
  }

  String _fmtDay(DateTime d) => DateFormat('yyyy-MM-dd').format(d);
  String _fmtTime(DateTime d) => DateFormat('HH:mm').format(d);

  // ---------- Per-class reminders ----------
  bool _classRemindEnabled(String classId) {
    final p = _prefs;
    if (p == null) return true; // default ON until prefs loaded
    return p.getBool('$_classRemindPrefix$classId') ?? true;
  }

  Future<void> _setClassRemindEnabled(String classId, bool value) async {
    final p = _prefs;
    if (p == null) return;
    await p.setBool('$_classRemindPrefix$classId', value);
    if (!mounted) return;
    setState(() {});
  }

  // ---------- Schedule computation ----------
  int _weekdayFromShort(String day) {
    switch (day) {
      case 'Mon':
        return DateTime.monday;
      case 'Tue':
        return DateTime.tuesday;
      case 'Wed':
        return DateTime.wednesday;
      case 'Thu':
        return DateTime.thursday;
      case 'Fri':
        return DateTime.friday;
      case 'Sat':
        return DateTime.saturday;
      case 'Sun':
        return DateTime.sunday;
      default:
        return DateTime.monday;
    }
  }

  DateTime? _parseFirstDate(Map<String, dynamic> cls) {
    final sched =
    (cls['schedule'] is Map) ? Map<String, dynamic>.from(cls['schedule']) : {};
    final first = (sched['first_session_date'] ?? '').toString();
    if (first.isEmpty) return null;
    try {
      return DateTime.parse(first);
    } catch (_) {
      return null;
    }
  }

  List<Map<String, dynamic>> _sessionsPattern(Map<String, dynamic> cls) {
    final sched =
    (cls['schedule'] is Map) ? Map<String, dynamic>.from(cls['schedule']) : {};
    final raw = sched['sessions'];
    if (raw is! List) return [];
    return raw
        .map((e) => e is Map ? Map<String, dynamic>.from(e) : <String, dynamic>{})
        .toList();
  }

  int _sessionsCount(Map<String, dynamic> cls) {
    final sched =
    (cls['schedule'] is Map) ? Map<String, dynamic>.from(cls['schedule']) : {};
    final c = sched['sessions_count'];
    return int.tryParse((c ?? '').toString()) ?? 0;
  }

  List<_Occ> _generateOccurrences(Map<String, dynamic> cls, {int daysAhead = 45}) {
    final status = (cls['status'] ?? 'active').toString();
    if (status != 'active') return [];

    final firstDate = _parseFirstDate(cls);
    if (firstDate == null) return [];

    final pattern = _sessionsPattern(cls);
    final countLimit = _sessionsCount(cls);
    if (pattern.isEmpty || countLimit <= 0) return [];

    final now = DateTime.now();
    final endWindow = now.add(Duration(days: daysAhead));

    final occ = <_Occ>[];
    int generated = 0;

    DateTime cursor = DateTime(firstDate.year, firstDate.month, firstDate.day);

    for (int week = 0; week < 220; week++) {
      for (final s in pattern) {
        if (generated >= countLimit) break;

        final dayShort = (s['day'] ?? '').toString();
        final startTime = (s['start_time'] ?? '').toString();
        final durMin = int.tryParse((s['duration_min'] ?? '0').toString()) ?? 0;

        if (dayShort.isEmpty || startTime.isEmpty || durMin <= 0) continue;

        final targetWeekday = _weekdayFromShort(dayShort);
        final baseWeekday = cursor.weekday;
        int diff = targetWeekday - baseWeekday;
        if (diff < 0) diff += 7;
        final sessionDate = cursor.add(Duration(days: diff));

        final parts = startTime.split(':');
        if (parts.length != 2) continue;
        final hh = int.tryParse(parts[0]) ?? 0;
        final mm = int.tryParse(parts[1]) ?? 0;

        final start =
        DateTime(sessionDate.year, sessionDate.month, sessionDate.day, hh, mm);
        final end = start.add(Duration(minutes: durMin));

        if (start.isBefore(firstDate)) continue;
        if (start.isAfter(endWindow)) continue;

        occ.add(_Occ(
          classId: (cls['class_id'] ?? '').toString(),
          courseCode: (cls['course_code'] ?? '').toString(),
          courseTitle: (cls['course_title'] ?? '').toString(),
          instructor: (cls['instructor'] ?? '').toString(),
          start: start,
          end: end,
        ));

        generated++;
      }

      if (generated >= countLimit) break;
      cursor = cursor.add(const Duration(days: 7));
      if (cursor.isAfter(endWindow.add(const Duration(days: 7)))) break;
    }

    occ.sort((a, b) => a.start.compareTo(b.start));
    return occ;
  }

  // ---------- Reminders ----------
  Future<void> _applyAllReminders({required List<_Occ> upcoming}) async {
    final granted = await NotificationService.I.requestPermissions();
    if (!granted) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Notification permission not granted')),
      );
      return;
    }

    // Rebuild safely
    await NotificationService.I.cancelAll();

    if (_dailyEnabled) {
      await NotificationService.I.scheduleDailyReminder(
        hour: _dailyHour,
        minute: _dailyMinute,
        title: 'Today’s classes',
        body: 'You have classes today. Open the app to see your schedule.',
      );
    }

    if (_sessionEnabled) {
      final now = DateTime.now();

      // Only schedule sessions for classes toggled ON
      final filtered = upcoming.where((o) => _classRemindEnabled(o.classId)).toList();

      // Limit to avoid spam
      final items = filtered.take(40).toList();

      for (final o in items) {
        if (o.start.isBefore(now)) continue;

        await NotificationService.I.scheduleSessionReminder(
          classId: o.classId,
          title: 'Class starts soon',
          body:
          '${o.courseCode} — ${o.courseTitle} at ${_fmtTime(o.start)} (Instructor: ${o.instructor})',
          sessionStart: o.start,
          minutesBefore: _minutesBefore, // 15
        );
      }
    }
  }

  Future<void> _toggleDaily(bool value, List<_Occ> upcoming) async {
    final p = _prefs;
    if (p == null) return;

    setState(() => _dailyEnabled = value);
    await p.setBool(_prefsDailyEnabled, _dailyEnabled);
    await _applyAllReminders(upcoming: upcoming);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(_dailyEnabled ? 'Daily reminder enabled' : 'Daily reminder disabled')),
    );
  }

  Future<void> _toggleSession(bool value, List<_Occ> upcoming) async {
    final p = _prefs;
    if (p == null) return;

    setState(() => _sessionEnabled = value);
    await p.setBool(_prefsSessionEnabled, _sessionEnabled);
    await _applyAllReminders(upcoming: upcoming);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(_sessionEnabled ? '15-min reminders enabled' : '15-min reminders disabled')),
    );
  }

  Future<void> _cancelAllNotifs() async {
    await NotificationService.I.cancelAll();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('All notifications cancelled')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final prefsLoaded = _prefs != null;

    return Scaffold(
      backgroundColor: appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        title: const Text(
          'Schedule',
          style: TextStyle(color: primaryBlue, fontWeight: FontWeight.w900),
        ),
        iconTheme: const IconThemeData(color: primaryBlue),
        actions: [
          IconButton(
            tooltip: 'Cancel all notifications',
            icon: const Icon(Icons.notifications_off_rounded, color: actionOrange),
            onPressed: _cancelAllNotifs,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: StreamBuilder<DatabaseEvent>(
          stream: _classesRef.onValue,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting || !prefsLoaded) {
              return const Center(child: CircularProgressIndicator());
            }

            final data = snap.data?.snapshot.value;
            if (data == null || data is! Map) {
              return const Center(child: Text('No classes yet.'));
            }

            final map = Map<dynamic, dynamic>.from(data);
            final classes = map.values
                .whereType<dynamic>()
                .map((e) => Map<String, dynamic>.from(e as Map))
                .toList();

            // Build occurrences
            final allOcc = <_Occ>[];
            for (final cls in classes) {
              allOcc.addAll(_generateOccurrences(cls, daysAhead: 45));
            }
            allOcc.sort((a, b) => a.start.compareTo(b.start));

            final now = DateTime.now();
            final upcoming = allOcc.where((o) => o.start.isAfter(now)).toList();

            // Calendar grouping
            final Map<String, List<_Occ>> byDay = {};
            for (final o in allOcc) {
              final key = _fmtDay(o.start);
              byDay.putIfAbsent(key, () => []);
              byDay[key]!.add(o);
            }

            final selected = _selectedDay ?? _focusedDay;
            final selectedKey = _fmtDay(selected);
            final selectedEvents =
            (byDay[selectedKey] ?? [])..sort((a, b) => a.start.compareTo(b.start));

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Mode switch
                Row(
                  children: [
                    Expanded(
                      child: SegmentedButton<int>(
                        segments: const [
                          ButtonSegment(
                            value: 0,
                            label: Text('Upcoming'),
                            icon: Icon(Icons.view_agenda_rounded),
                          ),
                          ButtonSegment(
                            value: 1,
                            label: Text('Calendar'),
                            icon: Icon(Icons.calendar_month_rounded),
                          ),
                        ],
                        selected: {_mode},
                        onSelectionChanged: (s) => setState(() => _mode = s.first),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 12),

                // Reminders box
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.grey.withOpacity(0.20)),
                  ),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.notifications_active_rounded, color: primaryBlue),
                          const SizedBox(width: 10),
                          const Expanded(
                            child: Text(
                              'Reminders',
                              style: TextStyle(fontWeight: FontWeight.w900, color: mainText),
                            ),
                          ),
                          Text(
                            '$_minutesBefore min',
                            style: TextStyle(
                              color: Colors.grey.shade700,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),

                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text(
                          'Daily reminder (8:00)',
                          style: TextStyle(fontWeight: FontWeight.w800),
                        ),
                        subtitle: const Text('“You have classes today”'),
                        value: _dailyEnabled,
                        onChanged: (v) => _toggleDaily(v, upcoming),
                      ),

                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text(
                          '15-min before each session',
                          style: TextStyle(fontWeight: FontWeight.w800),
                        ),
                        subtitle: const Text('Only for classes with “Remind me” ON'),
                        value: _sessionEnabled,
                        onChanged: (v) => _toggleSession(v, upcoming),
                      ),

                      const SizedBox(height: 6),

                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () => _applyAllReminders(upcoming: upcoming),
                          icon: const Icon(Icons.refresh_rounded),
                          label: const Text('Refresh reminders'),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 14),

                if (_mode == 0) ...[
                  Expanded(
                    child: upcoming.isEmpty
                        ? const Center(child: Text('No upcoming sessions in the next 45 days.'))
                        : ListView.separated(
                      itemCount: upcoming.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (_, i) {
                        final o = upcoming[i];
                        final enabled = _classRemindEnabled(o.classId);

                        return _SessionCard(
                          primaryBlue: primaryBlue,
                          actionOrange: actionOrange,
                          mainText: mainText,
                          o: o,
                          fmtDay: _fmtDay,
                          fmtTime: _fmtTime,
                          remindEnabled: enabled,
                          onToggleRemind: (v) async {
                            await _setClassRemindEnabled(o.classId, v);

                            // If reminders are ON, refresh scheduling
                            if (_sessionEnabled || _dailyEnabled) {
                              await _applyAllReminders(upcoming: upcoming);
                            }
                          },
                        );
                      },
                    ),
                  ),
                ] else ...[
                  TableCalendar(
                    firstDay: DateTime.now().subtract(const Duration(days: 365)),
                    lastDay: DateTime.now().add(const Duration(days: 365)),
                    focusedDay: _focusedDay,
                    selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
                    onDaySelected: (selectedDay, focusedDay) {
                      setState(() {
                        _selectedDay = selectedDay;
                        _focusedDay = focusedDay;
                      });
                    },
                    eventLoader: (day) => byDay[_fmtDay(day)] ?? [],
                    calendarStyle: CalendarStyle(
                      todayDecoration: BoxDecoration(
                        color: actionOrange.withOpacity(0.18),
                        shape: BoxShape.circle,
                        border: Border.all(color: actionOrange.withOpacity(0.45)),
                      ),
                      selectedDecoration: const BoxDecoration(
                        color: primaryBlue,
                        shape: BoxShape.circle,
                      ),
                      markerDecoration: const BoxDecoration(
                        color: actionOrange,
                        shape: BoxShape.circle,
                      ),
                    ),
                    headerStyle: const HeaderStyle(
                      formatButtonVisible: false,
                      titleCentered: true,
                      titleTextStyle: TextStyle(fontWeight: FontWeight.w900),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: selectedEvents.isEmpty
                        ? const Center(child: Text('No sessions on this day.'))
                        : ListView.separated(
                      itemCount: selectedEvents.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (_, i) {
                        final o = selectedEvents[i];
                        final enabled = _classRemindEnabled(o.classId);

                        return _SessionCard(
                          primaryBlue: primaryBlue,
                          actionOrange: actionOrange,
                          mainText: mainText,
                          o: o,
                          fmtDay: _fmtDay,
                          fmtTime: _fmtTime,
                          remindEnabled: enabled,
                          onToggleRemind: (v) async {
                            await _setClassRemindEnabled(o.classId, v);
                            if (_sessionEnabled || _dailyEnabled) {
                              await _applyAllReminders(upcoming: upcoming);
                            }
                          },
                        );
                      },
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Occ {
  final String classId;
  final String courseCode;
  final String courseTitle;
  final String instructor;
  final DateTime start;
  final DateTime end;

  _Occ({
    required this.classId,
    required this.courseCode,
    required this.courseTitle,
    required this.instructor,
    required this.start,
    required this.end,
  });
}

class _SessionCard extends StatelessWidget {
  const _SessionCard({
    required this.primaryBlue,
    required this.actionOrange,
    required this.mainText,
    required this.o,
    required this.fmtDay,
    required this.fmtTime,
    required this.remindEnabled,
    required this.onToggleRemind,
  });

  final Color primaryBlue;
  final Color actionOrange;
  final Color mainText;

  final _Occ o;
  final String Function(DateTime) fmtDay;
  final String Function(DateTime) fmtTime;

  final bool remindEnabled;
  final ValueChanged<bool> onToggleRemind;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: Colors.grey.withOpacity(0.25)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // TOP ROW: Date/time + classId badge
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${fmtDay(o.start)} • ${fmtTime(o.start)}',
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 15,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: actionOrange.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: actionOrange.withOpacity(0.35)),
                  ),
                  child: Text(
                    o.classId,
                    style: TextStyle(
                      color: primaryBlue,
                      fontWeight: FontWeight.w900,
                      fontSize: 11,
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 8),

            // PER-CLASS TOGGLE
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: remindEnabled
                    ? actionOrange.withOpacity(0.10)
                    : Colors.grey.withOpacity(0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: remindEnabled
                      ? actionOrange.withOpacity(0.35)
                      : Colors.grey.withOpacity(0.25),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    remindEnabled
                        ? Icons.notifications_active_rounded
                        : Icons.notifications_off_rounded,
                    color: remindEnabled ? actionOrange : Colors.grey.shade700,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Remind me for this class',
                      style: TextStyle(
                        color: mainText,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  Switch(
                    value: remindEnabled,
                    onChanged: onToggleRemind,
                    activeColor: actionOrange,
                  ),
                ],
              ),
            ),

            const SizedBox(height: 10),

            Text(
              '${o.courseCode} — ${o.courseTitle}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: mainText,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Instructor: ${o.instructor}',
              style: TextStyle(
                color: Colors.grey.shade700,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Ends: ${fmtTime(o.end)}',
              style: TextStyle(
                color: Colors.grey.shade700,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
