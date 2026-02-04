import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:table_calendar/table_calendar.dart';
import '../services/notification_service.dart';
import 'take_attendance_screen.dart';
import 'attendance_history_screen.dart';

class AdminScheduleScreen extends StatefulWidget {
  const AdminScheduleScreen({super.key});

  @override
  State<AdminScheduleScreen> createState() => _AdminScheduleScreenState();
}

class _AdminScheduleScreenState extends State<AdminScheduleScreen> {
  static const primaryBlue = Color(0xFF1A2B48);
  static const actionOrange = Color(0xFFF98D28);
  static const errorRed = Color(0xFFD32F2F);
  static const appBg = Color(0xFFF4F7F9);
  static const cardBorder = Color(0xFFE0E6ED);
  static const pastGrey = Color(0xFF9E9E9E); // Grey for finished classes

  final DatabaseReference _classesRef = FirebaseDatabase.instance.ref().child('classes');

  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;
  bool _dailyEnabled = false;
  bool _sessionEnabled = false;
  late SharedPreferences _prefs;
  bool _prefsReady = false;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    await NotificationService.I.init();
    _prefs = await SharedPreferences.getInstance();
    setState(() {
      _dailyEnabled = _prefs.getBool('reminders_daily_enabled') ?? false;
      _sessionEnabled = _prefs.getBool('reminders_session_enabled') ?? false;
      _prefsReady = true;
    });
  }

  String _fmtDayHeader(DateTime d) => DateFormat('EEEE, MMMM d').format(d);
  String _fmtKey(DateTime d) => DateFormat('yyyy-MM-dd').format(d);
  bool _isClassEnabled(String classId) => _prefs.getBool('remind_class_$classId') ?? true;

  bool _hasConflict(_Occ current, List<_Occ> allOnDay) {
    for (var other in allOnDay) {
      if (current == other) continue;
      if (current.start.isBefore(other.end) && other.start.isBefore(current.end)) {
        return true;
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: appBg,
        appBar: AppBar(
          backgroundColor: Colors.white,
          elevation: 0,
          title: const Text('Academy Schedule', style: TextStyle(color: primaryBlue, fontWeight: FontWeight.w900)),
          bottom: const TabBar(
            labelColor: primaryBlue,
            indicatorColor: actionOrange,
            tabs: [
              Tab(text: 'Schedule', icon: Icon(Icons.format_list_bulleted_rounded)),
              Tab(text: 'Calendar', icon: Icon(Icons.calendar_month_rounded)),
              Tab(text: 'Settings', icon: Icon(Icons.settings_rounded)),
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
            if (data == null || data is! Map) return const Center(child: Text('No classes found.'));

            final rawClasses = (data).values.map((e) => Map<String, dynamic>.from(e as Map)).toList();
            final allOcc = <_Occ>[];
            for (final cls in rawClasses) {
              allOcc.addAll(_generateOccurrences(cls));
            }
            allOcc.sort((a, b) => a.start.compareTo(b.start));

            // Logic: Show everything from 2 days ago until the future
            final now = DateTime.now();
            final twoDaysAgo = now.subtract(const Duration(days: 2));
            final recentAndUpcoming = allOcc.where((o) => o.end.isAfter(twoDaysAgo)).toList();

            return TabBarView(
              children: [
                _buildGroupedSchedule(recentAndUpcoming, allOcc, rawClasses),
                _buildCalendarView(allOcc, recentAndUpcoming, rawClasses),
                _buildSettingsView(recentAndUpcoming, allOcc),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildGroupedSchedule(List<_Occ> displayList, List<_Occ> allOcc, List<Map<String, dynamic>> rawClasses) {
    if (displayList.isEmpty) return const Center(child: Text('No recent or upcoming classes.'));
    final Map<String, List<_Occ>> grouped = {};
    for (var o in displayList) {
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
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
            child: Text(day, style: const TextStyle(color: primaryBlue, fontWeight: FontWeight.w800, fontSize: 15)),
          ),
          ...dayClasses.map((o) {
            final isConflict = _hasConflict(o, dayClasses);
            return _SessionCard(
              o: o,
              isConflict: isConflict,
              enabled: _isClassEnabled(o.classId),
              onToggle: () => _toggleClassNotif(o.classId, displayList, allOcc),
              onAttendance: () => _openAttendance(o, rawClasses),
              onHistory: () => _openHistory(o, rawClasses),
            );
          }),
        ]);
      },
    );
  }

  Widget _buildCalendarView(List<_Occ> allOcc, List<_Occ> upcoming, List<Map<String, dynamic>> rawClasses) {
    final Map<String, List<_Occ>> byDay = {};
    for (var o in allOcc) {
      final k = _fmtKey(o.start);
      byDay.putIfAbsent(k, () => []).add(o);
    }
    final selected = _selectedDay ?? _focusedDay;
    final events = byDay[_fmtKey(selected)] ?? [];

    return Column(children: [
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
        onDaySelected: (s, f) => setState(() { _selectedDay = s; _focusedDay = f; }),
        eventLoader: (day) => byDay[_fmtKey(day)] ?? [],
      ),
      const Divider(height: 1),
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
              onAttendance: () => _openAttendance(events[i], rawClasses),
              onHistory: () => _openHistory(events[i], rawClasses),
            );
          },
        ),
      ),
    ]);
  }

  // (Navigation and Setting logic remains the same as previous implementation)
  void _openAttendance(_Occ o, List<Map<String, dynamic>> rawClasses) {
    final classMap = rawClasses.firstWhere((c) => (c['class_id'] ?? c['id']) == o.classId);
    Navigator.push(context, MaterialPageRoute(builder: (_) => TakeAttendanceScreen(classData: classMap)));
  }

  void _openHistory(_Occ o, List<Map<String, dynamic>> rawClasses) {
    final classMap = rawClasses.firstWhere((c) => (c['class_id'] ?? c['id']) == o.classId);
    Navigator.push(context, MaterialPageRoute(builder: (_) => AttendanceHistoryScreen(classData: classMap)));
  }

  Widget _buildSettingsView(List<_Occ> upcoming, List<_Occ> allOcc) {
    return ListView(padding: const EdgeInsets.all(20), children: [
      const Text("Notifications", style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: primaryBlue)),
      const SizedBox(height: 16),
      Container(
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: cardBorder)),
        child: Column(children: [
          SwitchListTile(
            secondary: const Icon(Icons.wb_sunny_rounded, color: actionOrange),
            title: const Text("Daily Briefing (8:00 AM)"),
            value: _dailyEnabled,
            onChanged: (v) => _toggleDaily(v, upcoming, allOcc),
          ),
          const Divider(height: 1, indent: 50),
          SwitchListTile(
            secondary: const Icon(Icons.notifications_active_rounded, color: primaryBlue),
            title: const Text("Session Alerts (15m before)"),
            value: _sessionEnabled,
            onChanged: (v) => _toggleSession(v, upcoming, allOcc),
          ),
        ]),
      ),
    ]);
  }

  List<_Occ> _generateOccurrences(Map<String, dynamic> cls) {
    if (cls['status'] != 'active') return [];
    final firstDate = DateTime.tryParse(cls['schedule']?['first_session_date'] ?? '');
    if (firstDate == null) return [];
    final pattern = cls['schedule']?['sessions'] as List?;
    final countLimit = int.tryParse(cls['schedule']?['sessions_count']?.toString() ?? '0') ?? 0;
    if (pattern == null) return [];

    final List<_Occ> occ = [];
    DateTime cursor = DateTime(firstDate.year, firstDate.month, firstDate.day);
    for (int week = 0; week < 52; week++) {
      for (var s in pattern) {
        if (occ.length >= countLimit) break;
        final targetWeekday = _weekdayFromShort(s['day'] ?? 'Mon');
        int diff = targetWeekday - cursor.weekday;
        if (diff < 0) diff += 7;
        final sDate = cursor.add(Duration(days: diff));
        final timeParts = (s['start_time'] ?? '00:00').split(':');
        final start = DateTime(sDate.year, sDate.month, sDate.day, int.parse(timeParts[0]), int.parse(timeParts[1]));
        if (start.isBefore(firstDate)) continue;
        occ.add(_Occ(
          classId: (cls['class_id'] ?? cls['id'] ?? '').toString(),
          courseCode: cls['course_code'] ?? '',
          courseTitle: cls['course_title'] ?? '',
          start: start,
          end: start.add(Duration(minutes: int.parse(s['duration_min']?.toString() ?? '60'))),
        ));
      }
      cursor = cursor.add(const Duration(days: 7));
      if (occ.length >= countLimit) break;
    }
    return occ;
  }

  int _weekdayFromShort(String day) {
    const days = {'Mon': 1, 'Tue': 2, 'Wed': 3, 'Thu': 4, 'Fri': 5, 'Sat': 6, 'Sun': 7};
    return days[day] ?? 1;
  }

  Future<void> _toggleClassNotif(String classId, List<_Occ> up, List<_Occ> all) async {
    final current = _isClassEnabled(classId);
    await _prefs.setBool('remind_class_$classId', !current);
    setState(() {});
    await _applyAllReminders(upcoming: up, allOcc: all);
  }

  Future<void> _toggleDaily(bool v, List<_Occ> up, List<_Occ> all) async {
    setState(() => _dailyEnabled = v);
    await _prefs.setBool('reminders_daily_enabled', v);
    _applyAllReminders(upcoming: up, allOcc: all);
  }

  Future<void> _toggleSession(bool v, List<_Occ> up, List<_Occ> all) async {
    setState(() => _sessionEnabled = v);
    await _prefs.setBool('reminders_session_enabled', v);
    _applyAllReminders(upcoming: up, allOcc: all);
  }

  Future<void> _applyAllReminders({required List<_Occ> upcoming, required List<_Occ> allOcc}) async {
    await NotificationService.I.cancelAll();
    if (_dailyEnabled) {
      await NotificationService.I.scheduleDailyReminder(hour: 8, minute: 0, title: 'Classes Today', body: 'Open app to see today\'s schedule.');
    }
    if (_sessionEnabled) {
      for (var o in upcoming.where((e) => _isClassEnabled(e.classId)).take(30)) {
        await NotificationService.I.scheduleSessionReminder(classId: o.classId, title: 'Class Starting', body: '${o.courseCode} at ${DateFormat('hh:mm a').format(o.start)}', sessionStart: o.start, minutesBefore: 15);
      }
    }
  }
}

class _Occ {
  final String classId, courseCode, courseTitle;
  final DateTime start, end;
  _Occ({required this.classId, required this.courseCode, required this.courseTitle, required this.start, required this.end});
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

    // Determine status color
    Color statusColor = enabled ? const Color(0xFFF98D28) : Colors.grey.shade400;
    if (isConflict) statusColor = const Color(0xFFD32F2F);
    if (isLive) statusColor = const Color(0xFF1A2B48);
    if (isPast) statusColor = Colors.grey.shade400;

    return Opacity(
      opacity: isPast ? 0.7 : 1.0, // Mute past classes
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: isPast ? Colors.grey.shade50 : (isConflict ? const Color(0xFFFFEBEE) : Colors.white),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: isConflict ? const Color(0xFFD32F2F).withOpacity(0.3) : const Color(0xFFE0E6ED)),
          boxShadow: isLive ? [BoxShadow(color: const Color(0xFF1A2B48).withOpacity(0.1), blurRadius: 8, offset: const Offset(0, 4))] : null,
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
                            Text(DateFormat('hh:mm a').format(o.start),
                                style: TextStyle(
                                    fontWeight: FontWeight.w900,
                                    fontSize: 16,
                                    color: isPast ? Colors.grey : (isLive ? const Color(0xFF1A2B48) : const Color(0xFF2D2D2D)))),
                            const Spacer(),
                            if (isLive) _LiveBadge(),
                            if (isPast) const Text('FINISHED', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.grey)),
                            if (isConflict) const Icon(Icons.warning_rounded, color: Color(0xFFD32F2F), size: 20),
                            if (!isPast) // Don't show toggle for past classes
                              IconButton(
                                constraints: const BoxConstraints(),
                                padding: const EdgeInsets.only(left: 8),
                                icon: Icon(enabled ? Icons.notifications_active : Icons.notifications_off_outlined,
                                    color: enabled ? const Color(0xFFF98D28) : Colors.grey, size: 20),
                                onPressed: onToggle,
                              )
                          ],
                        ),
                        Text(o.courseTitle, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: isPast ? Colors.grey : Colors.black)),
                        Text('${o.courseCode} • ID: ${o.classId}', style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
                        const Divider(height: 20),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            _ActionButton(
                                label: isPast ? 'Update Attendance' : 'Take Attendance',
                                icon: isPast ? Icons.edit_note_rounded : Icons.how_to_reg_rounded,
                                color: isPast ? Colors.grey : const Color(0xFF1A2B48),
                                onTap: onAttendance),
                            const SizedBox(width: 8),
                            _ActionButton(label: 'History', icon: Icons.history_rounded, color: Colors.grey.shade700, onTap: onHistory),
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

// (The rest of the helper classes _LiveBadge and _ActionButton remain the same)
class _LiveBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: const Color(0xFF1A2B48), borderRadius: BorderRadius.circular(6)),
      child: const Row(
        children: [
          Icon(Icons.circle, color: Colors.red, size: 8),
          SizedBox(width: 4),
          Text('LIVE NOW', style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
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
  const _ActionButton({required this.label, required this.icon, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(border: Border.all(color: color.withOpacity(0.2)), borderRadius: BorderRadius.circular(8)),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 4),
              Text(label, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.bold)),
            ],
          ),
        ),
      ),
    );
  }
}