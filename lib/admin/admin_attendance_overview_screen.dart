import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import '../shared/admin_web_layout.dart';
import '../shared/human_error.dart';
import '../shared/admin_tour_guide.dart';
import '../shared/screen_help_guide.dart';

class AdminAttendanceOverviewScreen extends StatefulWidget {
  const AdminAttendanceOverviewScreen({super.key});

  @override
  State<AdminAttendanceOverviewScreen> createState() =>
      _AdminAttendanceOverviewScreenState();
}

class _AdminAttendanceOverviewScreenState
    extends State<AdminAttendanceOverviewScreen> {
  static const primaryBlue = Color(0xFF1A2B48);
  static const actionOrange = Color(0xFFF98D28);
  static const mainText = Color(0xFF2D2D2D);
  static const appBg = Color(0xFFF4F7F9);
  static const uiBorder = Color(0xFFD1D9E0);

  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  bool _loading = true;
  String? _error;

  late DateTime _fromDate;
  late DateTime _toDate;

  _StatsBucket rangeStats = _StatsBucket.zero();
  _StatsBucket rangeInClass = _StatsBucket.zero();
  _StatsBucket rangeOnline = _StatsBucket.zero();

  List<_AttendanceDetailRow> _rangeRows = [];
  List<_MissingAttendanceRow> _missingRows = [];

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _toDate = _dateOnly(now);
    _fromDate = DateTime(now.year, now.month, 1); // start of current month
    _load();
  }

  DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  DateTime? _parseYmd(String s) {
    try {
      final parts = s.split('-');
      if (parts.length != 3) return null;
      return DateTime(
        int.parse(parts[0]),
        int.parse(parts[1]),
        int.parse(parts[2]),
      );
    } catch (_) {
      return null;
    }
  }

  String _dateStr(DateTime d) {
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  String _safeStr(dynamic v) => (v ?? '').toString().trim();

  Map<String, dynamic> _safeMap(dynamic value) {
    if (value is Map) {
      return value.map((k, v) => MapEntry(k.toString(), v));
    }
    return <String, dynamic>{};
  }

  bool _isWithinRange(DateTime date) {
    final d = _dateOnly(date);
    return !d.isBefore(_fromDate) && !d.isAfter(_toDate);
  }

  String _teacherFromClassRecord(
    Map<String, dynamic> rec,
    Map<String, dynamic> classMap,
  ) {
    final recTeacher = _safeStr(rec['teacherName']);
    if (recTeacher.isNotEmpty) return recTeacher;

    final cur = classMap['instructor_current'];
    if (cur is Map) {
      final curMap = _safeMap(cur);
      final name = _safeStr(curMap['name']);
      if (name.isNotEmpty) return name;
    }

    final legacy = _safeStr(classMap['instructor']);
    if (legacy.isNotEmpty) return legacy;

    return 'Teacher';
  }

  String _classTitleFromClassMap(Map<String, dynamic> classMap) {
    final t = _safeStr(classMap['course_title']);
    if (t.isNotEmpty) return t;

    final code = _safeStr(classMap['course_code']);
    if (code.isNotEmpty) return code;

    final id = _safeStr(classMap['class_id']);
    if (id.isNotEmpty) return id;

    return 'Class';
  }

  String _courseTitleFromOnlineRecord(Map<String, dynamic> rec) {
    final title = _safeStr(rec['courseTitle']);
    if (title.isNotEmpty) return title;

    final title2 = _safeStr(rec['course_title']);
    if (title2.isNotEmpty) return title2;

    final courseId = _safeStr(rec['courseId']);
    if (courseId.isNotEmpty) return courseId;

    return 'Online Course';
  }

  int _weekdayFromShort(String day) {
    switch (day.trim()) {
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
        return -1;
    }
  }

  Future<void> _pickFromDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _fromDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;

    setState(() {
      _fromDate = _dateOnly(picked);
      if (_fromDate.isAfter(_toDate)) {
        _toDate = _fromDate;
      }
    });

    await _load();
  }

  Future<void> _pickToDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _toDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;

    setState(() {
      _toDate = _dateOnly(picked);
      if (_toDate.isBefore(_fromDate)) {
        _fromDate = _toDate;
      }
    });

    await _load();
  }

  void _openDetails({
    required String title,
    required List<_AttendanceDetailRow> rows,
    String? statusFilter,
  }) {
    List<_AttendanceDetailRow> filtered = rows;

    if (statusFilter != null && statusFilter.isNotEmpty) {
      filtered = rows.where((e) => e.status == statusFilter).toList();
    }

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            AdminAttendanceDetailsScreen(title: title, rows: filtered),
      ),
    );
  }

  void _openMissingDetails() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AdminMissingAttendanceScreen(
          title:
              'Missing Attendance (${_dateStr(_fromDate)} → ${_dateStr(_toDate)})',
          rows: _missingRows,
        ),
      ),
    );
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final now = _dateOnly(DateTime.now());

      _StatsBucket total = _StatsBucket.zero();
      _StatsBucket inClass = _StatsBucket.zero();
      _StatsBucket online = _StatsBucket.zero();

      final List<_AttendanceDetailRow> rangeRows = [];
      final List<_MissingAttendanceRow> missingRows = [];

      // uid -> user full name
      final Map<String, String> userNameByUid = {};

      // classId -> uid -> {name, serial}
      final Map<String, Map<String, Map<String, String>>>
      classLearnersByClassId = {};

      final usersSnap = await _db.child('users').get();
      if (usersSnap.exists && usersSnap.value is Map) {
        final usersMap = _safeMap(usersSnap.value);

        for (final entry in usersMap.entries) {
          final uid = entry.key.toString();
          final val = entry.value;
          if (val is! Map) continue;

          final m = _safeMap(val);
          final full =
              '${_safeStr(m['first_name'])} ${_safeStr(m['last_name'])}'.trim();
          userNameByUid[uid] = full.isEmpty ? 'Learner' : full;
        }
      }

      // =========================
      // IN-CLASS ATTENDANCE + MISSING
      // =========================
      final classesSnap = await _db.child('classes').get();
      if (classesSnap.exists && classesSnap.value is Map) {
        final classesMap = _safeMap(classesSnap.value);

        for (final classEntry in classesMap.entries) {
          try {
            final classId = classEntry.key.toString();
            final classVal = classEntry.value;
            if (classVal is! Map) continue;

            final classMap = _safeMap(classVal);
            final classTitle = _classTitleFromClassMap(classMap);

            // roster cache
            final rawLearners = classMap['learners'];
            final Map<String, Map<String, String>> roster = {};
            if (rawLearners is Map) {
              final lm = _safeMap(rawLearners);
              for (final learnerEntry in lm.entries) {
                final uid = learnerEntry.key.toString();
                final value = learnerEntry.value;

                if (value is Map) {
                  final mm = _safeMap(value);
                  roster[uid] = {
                    'name': _safeStr(mm['name']),
                    'serial': _safeStr(mm['serial']),
                  };
                } else {
                  roster[uid] = {'name': '', 'serial': ''};
                }
              }
            }
            classLearnersByClassId[classId] = roster;

            // attendance dates map
            final Set<String> attendanceDates = {};
            final attendance = classMap['attendance'];
            if (attendance is Map) {
              final attendanceMap = _safeMap(attendance);

              for (final attEntry in attendanceMap.entries) {
                try {
                  final recVal = attEntry.value;
                  if (recVal is! Map) continue;

                  final rec = _safeMap(recVal);
                  final dateStr = _safeStr(rec['date']);
                  final date = _parseYmd(dateStr);
                  if (date == null) continue;

                  attendanceDates.add(dateStr);

                  if (!_isWithinRange(date)) continue;

                  final teacherName = _teacherFromClassRecord(rec, classMap);

                  int present = 0;
                  int absent = 0;

                  final presentMapRaw = rec['present'];
                  final absentMapRaw = rec['absent'];

                  Map<String, dynamic> presentMap = {};
                  Map<String, dynamic> absentMap = {};

                  if (presentMapRaw is Map) {
                    presentMap = _safeMap(presentMapRaw);
                    present = presentMap.length;
                  }

                  if (absentMapRaw is Map) {
                    absentMap = _safeMap(absentMapRaw);
                    absent = absentMap.length;
                  }

                  final item = _StatsBucket(
                    sessions: 1,
                    present: present,
                    absent: absent,
                  );

                  total = total + item;
                  inClass = inClass + item;

                  final classRoster = classLearnersByClassId[classId] ?? {};

                  for (final uid in presentMap.keys) {
                    final learnerUid = uid.toString();
                    final rosterInfo =
                        classRoster[learnerUid] ?? const <String, String>{};

                    final rosterName = _safeStr(rosterInfo['name']);
                    final rosterSerial = _safeStr(rosterInfo['serial']);
                    final userName = _safeStr(userNameByUid[learnerUid]);

                    final resolvedName = rosterName.isNotEmpty
                        ? rosterName
                        : (userName.isNotEmpty
                              ? userName
                              : (rosterSerial.isNotEmpty
                                    ? rosterSerial
                                    : 'Learner'));

                    rangeRows.add(
                      _AttendanceDetailRow(
                        learnerUid: learnerUid,
                        learnerName: resolvedName,
                        learnerSerial: rosterSerial,
                        status: 'present',
                        teacherName: teacherName,
                        classOrCourseTitle: classTitle,
                        classId: classId,
                        source: 'In-class',
                        dateStr: dateStr,
                      ),
                    );
                  }

                  for (final uid in absentMap.keys) {
                    final learnerUid = uid.toString();
                    final rosterInfo =
                        classRoster[learnerUid] ?? const <String, String>{};

                    final rosterName = _safeStr(rosterInfo['name']);
                    final rosterSerial = _safeStr(rosterInfo['serial']);
                    final userName = _safeStr(userNameByUid[learnerUid]);

                    final resolvedName = rosterName.isNotEmpty
                        ? rosterName
                        : (userName.isNotEmpty
                              ? userName
                              : (rosterSerial.isNotEmpty
                                    ? rosterSerial
                                    : 'Learner'));

                    rangeRows.add(
                      _AttendanceDetailRow(
                        learnerUid: learnerUid,
                        learnerName: resolvedName,
                        learnerSerial: rosterSerial,
                        status: 'absent',
                        teacherName: teacherName,
                        classOrCourseTitle: classTitle,
                        classId: classId,
                        source: 'In-class',
                        dateStr: dateStr,
                      ),
                    );
                  }
                } catch (_) {}
              }
            }

            // Missing attendance detection
            final schedule = classMap['schedule'] is Map
                ? _safeMap(classMap['schedule'])
                : <String, dynamic>{};

            final firstSessionDateStr = _safeStr(
              schedule['first_session_date'],
            );
            final firstSessionDate = _parseYmd(firstSessionDateStr);

            final sessionsRaw = schedule['sessions'] is List
                ? List<dynamic>.from(schedule['sessions'])
                : <dynamic>[];
            final sessionsCount = (() {
              final raw = schedule['sessions_count'];
              if (raw is int) return raw;
              if (raw is num) return raw.toInt();
              return int.tryParse(raw?.toString() ?? '') ?? 0;
            })();

            final teacherName = _teacherFromClassRecord(
              const <String, dynamic>{},
              classMap,
            );
            final learnerCount = roster.length;

            if (firstSessionDate != null &&
                sessionsRaw.isNotEmpty &&
                sessionsCount > 0) {
              final DateTime endDate = _toDate.isAfter(now) ? now : _toDate;

              int occurrencesBuilt = 0;
              DateTime cursor = firstSessionDate;

              while (!cursor.isAfter(endDate) &&
                  occurrencesBuilt < sessionsCount) {
                final dateOnlyCursor = _dateOnly(cursor);

                for (final item in sessionsRaw) {
                  if (occurrencesBuilt >= sessionsCount) break;

                  if (item is! Map) continue;
                  final sm = _safeMap(item);

                  final day = _safeStr(sm['day']);
                  final startTime = _safeStr(sm['start_time']);
                  final durationMin = _safeStr(sm['duration_min']);

                  final weekday = _weekdayFromShort(day);
                  if (weekday == -1) continue;

                  if (dateOnlyCursor.weekday != weekday) continue;

                  occurrencesBuilt++;

                  if (dateOnlyCursor.isBefore(_fromDate) ||
                      dateOnlyCursor.isAfter(endDate)) {
                    continue;
                  }

                  final dateKey = _dateStr(dateOnlyCursor);
                  if (attendanceDates.contains(dateKey)) {
                    continue;
                  }

                  missingRows.add(
                    _MissingAttendanceRow(
                      classId: classId,
                      classTitle: classTitle,
                      teacherName: teacherName,
                      dateStr: dateKey,
                      startTime: startTime,
                      durationMin: durationMin,
                      learnerCount: learnerCount,
                    ),
                  );
                }

                cursor = cursor.add(const Duration(days: 1));
              }
            }
          } catch (_) {}
        }
      }

      // =========================
      // ONLINE ATTENDANCE
      // =========================
      try {
        final onlineSnap = await _db.child('online_attendance').get();
        if (onlineSnap.exists && onlineSnap.value is Map) {
          final onlineMap = _safeMap(onlineSnap.value);

          for (final entry in onlineMap.entries) {
            try {
              final recVal = entry.value;
              if (recVal is! Map) continue;

              final rec = _safeMap(recVal);
              final dayKey = _safeStr(rec['dayKey']);
              final date = _parseYmd(dayKey);
              if (date == null) continue;
              if (!_isWithinRange(date)) continue;

              final teacherName = _safeStr(rec['teacherName']).isNotEmpty
                  ? _safeStr(rec['teacherName'])
                  : 'Teacher';

              final classOrCourseTitle = _courseTitleFromOnlineRecord(rec);

              int present = 0;
              int absent = 0;

              final learnersRaw = rec['learners'];
              Map<String, dynamic> learnersMap = {};
              if (learnersRaw is Map) {
                learnersMap = _safeMap(learnersRaw);
              }

              for (final learnerEntry in learnersMap.entries) {
                final learnerUid = learnerEntry.key.toString();
                final learnerVal = learnerEntry.value;

                bool isPresent = false;
                if (learnerVal is Map) {
                  final learnerMap = _safeMap(learnerVal);
                  isPresent = learnerMap['present'] == true;
                }

                if (isPresent) {
                  present++;
                } else {
                  absent++;
                }

                final userName = _safeStr(userNameByUid[learnerUid]);

                rangeRows.add(
                  _AttendanceDetailRow(
                    learnerUid: learnerUid,
                    learnerName: userName.isNotEmpty ? userName : 'Learner',
                    learnerSerial: '',
                    status: isPresent ? 'present' : 'absent',
                    teacherName: teacherName,
                    classOrCourseTitle: classOrCourseTitle,
                    classId: '',
                    source: 'Online',
                    dateStr: dayKey,
                  ),
                );
              }

              final item = _StatsBucket(
                sessions: 1,
                present: present,
                absent: absent,
              );

              total = total + item;
              online = online + item;
            } catch (_) {}
          }
        }
      } catch (_) {}

      if (!mounted) return;
      setState(() {
        rangeStats = total;
        rangeInClass = inClass;
        rangeOnline = online;
        _rangeRows = rangeRows;
        _missingRows = missingRows;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = toHumanError(
          e,
          fallback: 'Could not load attendance overview. Please try again.',
        );
        _loading = false;
      });
    }
  }

  String _pct(_StatsBucket s) {
    final total = s.present + s.absent;
    if (total <= 0) return '0%';
    final value = ((s.present / total) * 100).round();
    return '$value%';
  }

  Widget _topCard({
    required String title,
    required String value,
    required IconData icon,
    VoidCallback? onTap,
  }) {
    final child = Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: uiBorder.withValues(alpha: 0.85)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: actionOrange, size: 20),
          const SizedBox(height: 10),
          Text(
            value,
            style: const TextStyle(
              color: primaryBlue,
              fontWeight: FontWeight.w900,
              fontSize: 20,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            title,
            style: TextStyle(
              color: Colors.grey.shade700,
              fontWeight: FontWeight.w800,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );

    if (onTap == null) return child;

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: child,
    );
  }

  Widget _rangePickerCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: uiBorder.withValues(alpha: 0.85)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Date Range',
            style: TextStyle(
              color: primaryBlue,
              fontWeight: FontWeight.w900,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _loading ? null : _pickFromDate,
                  icon: const Icon(Icons.calendar_month_rounded),
                  label: Text('From: ${_dateStr(_fromDate)}'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _loading ? null : _pickToDate,
                  icon: const Icon(Icons.event_rounded),
                  label: Text('To: ${_dateStr(_toDate)}'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _summarySection({
    required String title,
    required _StatsBucket data,
    required _StatsBucket inClass,
    required _StatsBucket online,
    required List<_AttendanceDetailRow> rows,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: uiBorder.withValues(alpha: 0.85)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: primaryBlue,
              fontWeight: FontWeight.w900,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _miniStat(
                  label: 'Records',
                  value: '${rows.length}',
                  icon: Icons.list_alt_rounded,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _miniStat(
                  label: 'Present',
                  value: '${data.present}',
                  icon: Icons.check_circle_rounded,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _miniStat(
                  label: 'Absent',
                  value: '${data.absent}',
                  icon: Icons.cancel_rounded,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _wideStat(
            label: 'Attendance Rate',
            value: _pct(data),
            icon: Icons.pie_chart_rounded,
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: () =>
                    _openDetails(title: '$title - All', rows: rows),
                icon: const Icon(Icons.list_alt_rounded),
                label: const Text('View All'),
              ),
              OutlinedButton.icon(
                onPressed: () => _openDetails(
                  title: '$title - Present',
                  rows: rows,
                  statusFilter: 'present',
                ),
                icon: const Icon(Icons.check_circle_outline_rounded),
                label: const Text('Present'),
              ),
              OutlinedButton.icon(
                onPressed: () => _openDetails(
                  title: '$title - Absent',
                  rows: rows,
                  statusFilter: 'absent',
                ),
                icon: const Icon(Icons.highlight_off_rounded),
                label: const Text('Absent'),
              ),
            ],
          ),
          const SizedBox(height: 14),
          const Divider(height: 1),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _sourceBox(
                  title: 'In-class',
                  sessions: inClass.sessions,
                  present: inClass.present,
                  absent: inClass.absent,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _sourceBox(
                  title: 'Online',
                  sessions: online.sessions,
                  present: online.present,
                  absent: online.absent,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _missingSection() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: uiBorder.withValues(alpha: 0.85)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Missing Attendance',
            style: TextStyle(
              color: primaryBlue,
              fontWeight: FontWeight.w900,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Scheduled classes with no attendance submitted in the selected range.',
            style: TextStyle(
              color: Colors.grey.shade700,
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _miniStat(
                  label: 'Missing Days',
                  value: '${_missingRows.length}',
                  icon: Icons.warning_amber_rounded,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _miniStat(
                  label: 'Affected Classes',
                  value: '${_missingRows.map((e) => e.classId).toSet().length}',
                  icon: Icons.class_rounded,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _miniStat(
                  label: 'Teachers',
                  value:
                      '${_missingRows.map((e) => e.teacherName).toSet().length}',
                  icon: Icons.badge_rounded,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _missingRows.isEmpty ? null : _openMissingDetails,
              icon: const Icon(Icons.fact_check_rounded),
              label: const Text('View Missing Attendance List'),
            ),
          ),
          if (_missingRows.isNotEmpty) ...[
            const SizedBox(height: 14),
            ..._missingRows.take(5).map((row) {
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: appBg,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: uiBorder.withValues(alpha: 0.85)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      row.classTitle,
                      style: const TextStyle(
                        color: primaryBlue,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Class ID: ${row.classId} • Date: ${row.dateStr}',
                      style: const TextStyle(
                        color: mainText,
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Teacher: ${row.teacherName} • Time: ${row.startTime.isEmpty ? "-" : row.startTime}',
                      style: const TextStyle(
                        color: mainText,
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        ],
      ),
    );
  }

  Widget _miniStat({
    required String label,
    required String value,
    required IconData icon,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: appBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: uiBorder.withValues(alpha: 0.85)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: primaryBlue, size: 18),
          const SizedBox(height: 8),
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
              fontWeight: FontWeight.w700,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  Widget _wideStat({
    required String label,
    required String value,
    required IconData icon,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: actionOrange.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: actionOrange.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Icon(icon, color: actionOrange, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                color: primaryBlue,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              color: actionOrange,
              fontWeight: FontWeight.w900,
              fontSize: 16,
            ),
          ),
        ],
      ),
    );
  }

  Widget _sourceBox({
    required String title,
    required int sessions,
    required int present,
    required int absent,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: appBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: uiBorder.withValues(alpha: 0.85)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: primaryBlue,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Sessions: $sessions',
            style: const TextStyle(
              color: mainText,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Present: $present',
            style: const TextStyle(
              color: mainText,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Absent: $absent',
            style: const TextStyle(
              color: mainText,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _errorState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          _error ?? 'Unknown error',
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Colors.red,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    AdminTourGuide.scheduleSimple(
      context,
      screenId: 'admin_attendance_overview',
      title: 'ملخص الحضور',
      line: 'تعرض هذه الشاشة احصائيات الحضور ضمن الفترة الزمنية المختارة.',
    );

    final rangeTitle =
        'Selected Range (${_dateStr(_fromDate)} → ${_dateStr(_toDate)})';

    return Scaffold(
      backgroundColor: appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: primaryBlue),
        title: const Text(
          'Attendance Overview',
          style: TextStyle(color: primaryBlue, fontWeight: FontWeight.w900),
        ),
        actions: [
          const SizedBox.shrink(),
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded, color: actionOrange),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: adminWebBodyFrame(
        context: context,
        maxWidth: 1560,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? _errorState()
            : ListView(
                padding: const EdgeInsets.all(14),
                children: [
                  _rangePickerCard(),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: _topCard(
                          title: 'Present',
                          value: '${rangeStats.present}',
                          icon: Icons.check_circle_rounded,
                          onTap: () => _openDetails(
                            title: '$rangeTitle - Present',
                            rows: _rangeRows,
                            statusFilter: 'present',
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _topCard(
                          title: 'Absent',
                          value: '${rangeStats.absent}',
                          icon: Icons.cancel_rounded,
                          onTap: () => _openDetails(
                            title: '$rangeTitle - Absent',
                            rows: _rangeRows,
                            statusFilter: 'absent',
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _topCard(
                          title: 'Records',
                          value: '${_rangeRows.length}',
                          icon: Icons.event_rounded,
                          onTap: () => _openDetails(
                            title: '$rangeTitle - All',
                            rows: _rangeRows,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  _summarySection(
                    title: rangeTitle,
                    data: rangeStats,
                    inClass: rangeInClass,
                    online: rangeOnline,
                    rows: _rangeRows,
                  ),
                  const SizedBox(height: 14),
                  _missingSection(),
                ],
              ),
      ),
    );
  }
}

class AdminAttendanceDetailsScreen extends StatelessWidget {
  const AdminAttendanceDetailsScreen({
    super.key,
    required this.title,
    required this.rows,
  });

  final String title;
  final List<_AttendanceDetailRow> rows;

  static const primaryBlue = Color(0xFF1A2B48);
  static const mainText = Color(0xFF2D2D2D);
  static const appBg = Color(0xFFF4F7F9);
  static const uiBorder = Color(0xFFD1D9E0);

  Color _statusColor(String status) {
    return status == 'present' ? Colors.green : Colors.red;
  }

  @override
  Widget build(BuildContext context) {
    AdminTourGuide.scheduleSimple(
      context,
      screenId: 'admin_attendance_details',
      title: 'تفاصيل الحضور',
      line: 'هنا تظهر سجلات الحضور التفصيلية لكل متعلم داخل الصف.',
    );

    final sorted = [...rows]
      ..sort((a, b) {
        final dateCmp = b.dateStr.compareTo(a.dateStr);
        if (dateCmp != 0) return dateCmp;
        return a.learnerName.toLowerCase().compareTo(
          b.learnerName.toLowerCase(),
        );
      });

    return Scaffold(
      backgroundColor: appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: primaryBlue),
        title: Text(
          title,
          style: const TextStyle(
            color: primaryBlue,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
      body: adminWebBodyFrame(
        context: context,
        maxWidth: 1320,
        child: sorted.isEmpty
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'No attendance details found.',
                    style: TextStyle(
                      color: mainText,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              )
            : ListView.builder(
                padding: const EdgeInsets.all(14),
                itemCount: sorted.length,
                itemBuilder: (_, i) {
                  final row = sorted[i];
                  final color = _statusColor(row.status);

                  return Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: uiBorder.withValues(alpha: 0.85),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            CircleAvatar(
                              radius: 16,
                              backgroundColor: color.withValues(alpha: 0.10),
                              child: Icon(
                                row.status == 'present'
                                    ? Icons.check
                                    : Icons.close,
                                color: color,
                                size: 18,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                row.learnerName,
                                style: const TextStyle(
                                  color: primaryBlue,
                                  fontWeight: FontWeight.w900,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: color.withValues(alpha: 0.10),
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(
                                  color: color.withValues(alpha: 0.25),
                                ),
                              ),
                              child: Text(
                                row.status == 'present' ? 'Present' : 'Absent',
                                style: TextStyle(
                                  color: color,
                                  fontWeight: FontWeight.w900,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        _detailLine('Teacher', row.teacherName),
                        const SizedBox(height: 4),
                        _detailLine('Class / Course', row.classOrCourseTitle),
                        if (row.classId.trim().isNotEmpty) ...[
                          const SizedBox(height: 4),
                          _detailLine('Class ID', row.classId),
                        ],
                        if (row.learnerSerial.trim().isNotEmpty) ...[
                          const SizedBox(height: 4),
                          _detailLine('Serial', row.learnerSerial),
                        ],
                        const SizedBox(height: 4),
                        _detailLine('Source', row.source),
                        const SizedBox(height: 4),
                        _detailLine('Date', row.dateStr),
                      ],
                    ),
                  );
                },
              ),
      ),
    );
  }

  Widget _detailLine(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 100,
          child: Text(
            '$label:',
            style: TextStyle(
              color: Colors.grey.shade700,
              fontWeight: FontWeight.w800,
              fontSize: 12,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value.trim().isEmpty ? '-' : value,
            style: const TextStyle(
              color: mainText,
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
        ),
      ],
    );
  }
}

class AdminMissingAttendanceScreen extends StatelessWidget {
  const AdminMissingAttendanceScreen({
    super.key,
    required this.title,
    required this.rows,
  });

  final String title;
  final List<_MissingAttendanceRow> rows;

  static const primaryBlue = Color(0xFF1A2B48);
  static const mainText = Color(0xFF2D2D2D);
  static const appBg = Color(0xFFF4F7F9);
  static const uiBorder = Color(0xFFD1D9E0);

  @override
  Widget build(BuildContext context) {
    AdminTourGuide.scheduleSimple(
      context,
      screenId: 'admin_missing_attendance',
      title: 'الحصص بدون حضور',
      line: 'هذه الشاشة تعرض الحصص التي لا تحتوي على سجلات حضور مكتملة.',
    );

    final sorted = [...rows]
      ..sort((a, b) {
        final dateCmp = a.dateStr.compareTo(b.dateStr);
        if (dateCmp != 0) return dateCmp;
        return a.classTitle.toLowerCase().compareTo(b.classTitle.toLowerCase());
      });

    return Scaffold(
      backgroundColor: appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: primaryBlue),
        title: Text(
          title,
          style: const TextStyle(
            color: primaryBlue,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
      body: adminWebBodyFrame(
        context: context,
        maxWidth: 1320,
        child: sorted.isEmpty
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'No missing attendance found.',
                    style: TextStyle(
                      color: mainText,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              )
            : ListView.builder(
                padding: const EdgeInsets.all(14),
                itemCount: sorted.length,
                itemBuilder: (_, i) {
                  final row = sorted[i];

                  return Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: uiBorder.withValues(alpha: 0.85),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Row(
                          children: [
                            Icon(
                              Icons.warning_amber_rounded,
                              color: Colors.orange,
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Attendance not submitted',
                                style: TextStyle(
                                  color: primaryBlue,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        _detailLine('Class / Course', row.classTitle),
                        const SizedBox(height: 4),
                        _detailLine('Class ID', row.classId),
                        const SizedBox(height: 4),
                        _detailLine('Teacher', row.teacherName),
                        const SizedBox(height: 4),
                        _detailLine('Date', row.dateStr),
                        const SizedBox(height: 4),
                        _detailLine(
                          'Time',
                          row.startTime.isEmpty ? '-' : row.startTime,
                        ),
                        const SizedBox(height: 4),
                        _detailLine(
                          'Duration',
                          row.durationMin.isEmpty
                              ? '-'
                              : '${row.durationMin} min',
                        ),
                        const SizedBox(height: 4),
                        _detailLine('Learners', '${row.learnerCount}'),
                      ],
                    ),
                  );
                },
              ),
      ),
    );
  }

  Widget _detailLine(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 100,
          child: Text(
            '$label:',
            style: TextStyle(
              color: Colors.grey.shade700,
              fontWeight: FontWeight.w800,
              fontSize: 12,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value.trim().isEmpty ? '-' : value,
            style: const TextStyle(
              color: mainText,
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
        ),
      ],
    );
  }
}

class _AttendanceDetailRow {
  final String learnerUid;
  final String learnerName;
  final String learnerSerial;
  final String status;
  final String teacherName;
  final String classOrCourseTitle;
  final String classId;
  final String source;
  final String dateStr;

  const _AttendanceDetailRow({
    required this.learnerUid,
    required this.learnerName,
    required this.learnerSerial,
    required this.status,
    required this.teacherName,
    required this.classOrCourseTitle,
    required this.classId,
    required this.source,
    required this.dateStr,
  });
}

class _MissingAttendanceRow {
  final String classId;
  final String classTitle;
  final String teacherName;
  final String dateStr;
  final String startTime;
  final String durationMin;
  final int learnerCount;

  const _MissingAttendanceRow({
    required this.classId,
    required this.classTitle,
    required this.teacherName,
    required this.dateStr,
    required this.startTime,
    required this.durationMin,
    required this.learnerCount,
  });
}

class _StatsBucket {
  final int sessions;
  final int present;
  final int absent;

  const _StatsBucket({
    required this.sessions,
    required this.present,
    required this.absent,
  });

  factory _StatsBucket.zero() =>
      const _StatsBucket(sessions: 0, present: 0, absent: 0);

  _StatsBucket operator +(_StatsBucket other) {
    return _StatsBucket(
      sessions: sessions + other.sessions,
      present: present + other.present,
      absent: absent + other.absent,
    );
  }
}
