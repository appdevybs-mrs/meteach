import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../shared/admin_web_layout.dart';
import '../shared/app_feedback.dart';
import '../shared/human_error.dart';
import '../shared/profile_avatar.dart';

class AdminWagesScreen extends StatefulWidget {
  const AdminWagesScreen({super.key});

  static const primaryBlue = Color(0xFF1A2B48);
  static const uiBorder = Color(0xFFD1D9E0);
  static const actionOrange = Color(0xFFF98D28);
  static const appBg = Color(0xFFF4F7F9);

  @override
  State<AdminWagesScreen> createState() => _AdminWagesScreenState();
}

class _AdminWagesScreenState extends State<AdminWagesScreen> {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  final TextEditingController _searchC = TextEditingController();
  String _search = '';

  @override
  void initState() {
    super.initState();
    _searchC.addListener(() {
      if (!mounted) return;
      setState(() => _search = _searchC.text.trim().toLowerCase());
    });
  }

  @override
  void dispose() {
    _searchC.dispose();
    super.dispose();
  }

  static int _asInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is num) return v.toInt();
    final clean = v.toString().trim().replaceAll(RegExp(r'[^0-9-]'), '');
    return int.tryParse(clean) ?? 0;
  }

  static bool _asBool(dynamic v) {
    if (v == null) return false;
    if (v is bool) return v;
    final s = v.toString().trim().toLowerCase();
    return s == 'true' || s == '1' || s == 'yes';
  }

  static String _safeString(dynamic v) => (v ?? '').toString().trim();

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _ymdFromMs(int ms) {
    if (ms <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.year}-${_two(d.month)}-${_two(d.day)}';
  }

  static int _sortMsFromYmd(String ymd) {
    final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(ymd.trim());
    if (m == null) return 0;
    final year = int.tryParse(m.group(1) ?? '') ?? 0;
    final month = int.tryParse(m.group(2) ?? '') ?? 0;
    final day = int.tryParse(m.group(3) ?? '') ?? 0;
    if (year <= 0 || month <= 0 || day <= 0) return 0;
    return DateTime(year, month, day).millisecondsSinceEpoch;
  }

  static String _normalizeVariant(dynamic v) {
    final s = (v ?? '').toString().trim().toLowerCase();
    if (s == 'flexible' || s == 'online' || s == 'booking') return 'flexible';
    if (s == 'recorded' || s == 'on_demand' || s == 'ondemand')
      return 'recorded';
    if (s == 'private' || s == 'one_to_one') return 'private';
    return 'inclass';
  }

  static bool _isTeacherRole(dynamic role) {
    return role.toString().trim().toLowerCase() == 'teacher';
  }

  static String _fullNameFromMap(Map<String, dynamic> m, String fallback) {
    final direct = _safeString(m['name'] ?? m['fullName'] ?? m['displayName']);
    if (direct.isNotEmpty) return direct;
    final first = _safeString(m['first_name'] ?? m['firstName']);
    final last = _safeString(m['last_name'] ?? m['lastName']);
    final full = '$first $last'.trim();
    return full.isEmpty ? fallback : full;
  }

  static Map<String, _PersonInfo> _parsePeople(dynamic raw) {
    final out = <String, _PersonInfo>{};
    if (raw is! Map) return out;
    raw.forEach((key, value) {
      final uid = key.toString().trim();
      if (uid.isEmpty || value is! Map) return;
      final map = value
          .map((k, v) => MapEntry(k.toString(), v))
          .cast<String, dynamic>();
      final role = _safeString(map['role']).toLowerCase();
      final fallback = _isTeacherRole(role) ? 'Teacher' : 'Learner';
      out[uid] = _PersonInfo(
        uid: uid,
        name: _fullNameFromMap(map, fallback),
        serial: _safeString(map['serial'] ?? map['learner_serial']),
        role: role,
        photoUrl: ProfileAvatar.resolvePhotoFromMap(map),
        fallbackLevel: _fallbackLevelFromUserMap(map),
      );
    });
    return out;
  }

  static String _fallbackLevelFromUserMap(Map<String, dynamic> map) {
    final courses = map['courses'];
    if (courses is! Map) return '';
    final levels = <String>{};
    courses.forEach((_, courseValue) {
      if (courseValue is! Map) return;
      final course = courseValue.map((k, v) => MapEntry(k.toString(), v));
      final variant = _normalizeVariant(
        course['variantKey'] ?? course['variant'],
      );
      if (variant == 'recorded') return;
      final classMap = course['class'] is Map
          ? (course['class'] as Map).map((k, v) => MapEntry(k.toString(), v))
          : <String, dynamic>{};
      final level = _safeString(
        course['course_level'] ??
            course['level'] ??
            classMap['course_level'] ??
            classMap['level'],
      );
      if (level.isNotEmpty) levels.add(level);
    });
    if (levels.isEmpty) return '';
    final sorted = levels.toList()..sort();
    return sorted.first;
  }

  static String _variantLabel(String variant) {
    switch (_normalizeVariant(variant)) {
      case 'flexible':
        return 'Flexible';
      case 'private':
        return 'Private';
      case 'recorded':
        return 'Recorded';
      default:
        return 'In-class';
    }
  }

  static String _classGroupTitle(Map<String, dynamic> cls, String classKey) {
    final level = _safeString(cls['course_level'] ?? cls['level']);
    final code = _safeString(cls['course_code']);
    final title = _safeString(cls['course_title'] ?? cls['title']);
    final parts = <String>[
      if (level.isNotEmpty) level,
      if (code.isNotEmpty) code,
      if (title.isNotEmpty) title,
    ];
    if (parts.isEmpty) return classKey.isEmpty ? 'Class' : 'Class $classKey';
    return parts.join(' - ');
  }

  static String _classGroupSubtitle(Map<String, dynamic> cls, String classKey) {
    final classId = _safeString(cls['class_id']).isNotEmpty
        ? _safeString(cls['class_id'])
        : classKey;
    final variant = _variantLabel(
      _safeString(cls['variantKey'] ?? cls['variant']),
    );
    return [if (classId.isNotEmpty) 'Class: $classId', variant].join(' • ');
  }

  static bool _flexConsumesCredit(Map<String, dynamic> m) {
    if (_asBool(m['countedCredit'])) return true;
    if (_asBool(m['present'])) return true;
    final status = _safeString(m['status']).toLowerCase();
    if (status == 'present') return true;
    return _asInt(m['sessionNo']) > 0;
  }

  static _WageSourceData _buildSourceData({
    required Map<String, _PersonInfo> people,
    required dynamic classesRaw,
    required dynamic bookingProgressRaw,
  }) {
    final learnerUidsByTeacher = <String, Set<String>>{};
    final attendanceByTeacherLearner = <String, List<_AttendanceOption>>{};
    final classGroupsByTeacher = <String, Map<String, _LearnerGroup>>{};

    void addLearner(String teacherUid, String learnerUid) {
      final t = teacherUid.trim();
      final l = learnerUid.trim();
      if (t.isEmpty || l.isEmpty) return;
      learnerUidsByTeacher.putIfAbsent(t, () => <String>{}).add(l);
    }

    void addAttendance({
      required String teacherUid,
      required String learnerUid,
      required _AttendanceOption option,
    }) {
      addLearner(teacherUid, learnerUid);
      final key = _pairKey(teacherUid, learnerUid);
      attendanceByTeacherLearner
          .putIfAbsent(key, () => <_AttendanceOption>[])
          .add(option);
    }

    void addToClassGroup({
      required String teacherUid,
      required String groupId,
      required String title,
      required String subtitle,
      required String learnerUid,
      Map<String, dynamic>? classData,
    }) {
      final teacher = teacherUid.trim();
      final learner = learnerUid.trim();
      if (teacher.isEmpty || learner.isEmpty) return;
      addLearner(teacher, learner);
      final groupMap = classGroupsByTeacher.putIfAbsent(
        teacher,
        () => <String, _LearnerGroup>{},
      );
      final group = groupMap.putIfAbsent(
        groupId,
        () => _LearnerGroup(
          id: groupId,
          title: title,
          subtitle: subtitle,
          kind: 'class',
          learners: <_PersonInfo>[],
          classData: classData,
        ),
      );
      final person =
          people[learner] ??
          _PersonInfo(
            uid: learner,
            name: learner,
            serial: '',
            role: 'learner',
            photoUrl: '',
            fallbackLevel: '',
          );
      if (!group.learners.any((p) => p.uid == person.uid)) {
        group.learners.add(person);
      }
    }

    if (classesRaw is Map) {
      classesRaw.forEach((classKey, classValue) {
        if (classValue is! Map) return;
        final cls = classValue
            .map((k, v) => MapEntry(k.toString(), v))
            .cast<String, dynamic>();
        final variant = _normalizeVariant(
          cls['variantKey'] ?? cls['variant'] ?? cls['deliveryKey'],
        );
        if (variant == 'recorded') return;

        String classTeacherUid = _safeString(
          cls['teacherId'] ?? cls['teacher_id'],
        );
        final current = cls['instructor_current'];
        if (current is Map) {
          final cur = current.map((k, v) => MapEntry(k.toString(), v));
          final uid = _safeString(cur['uid'] ?? cur['teacherId'] ?? cur['id']);
          if (uid.isNotEmpty) classTeacherUid = uid;
        }

        final learners = cls['learners'];
        if (learners is Map && classTeacherUid.isNotEmpty) {
          final classId = _safeString(cls['class_id']).isNotEmpty
              ? _safeString(cls['class_id'])
              : classKey.toString();
          final groupId = 'class|$classId';
          final groupTitle = _classGroupTitle(cls, classId);
          final groupSubtitle = _classGroupSubtitle(cls, classId);
          for (final learnerKey in learners.keys) {
            addToClassGroup(
              teacherUid: classTeacherUid,
              groupId: groupId,
              title: groupTitle,
              subtitle: groupSubtitle,
              learnerUid: learnerKey.toString(),
              classData: cls,
            );
          }
        }

        if (variant == 'flexible') return;
        final attendance = cls['attendance'];
        if (attendance is! Map) return;
        attendance.forEach((sessionKey, sessionValue) {
          if (sessionValue is! Map) return;
          final rec = sessionValue
              .map((k, v) => MapEntry(k.toString(), v))
              .cast<String, dynamic>();
          final recTeacherUid = _safeString(rec['teacherUid']).isNotEmpty
              ? _safeString(rec['teacherUid'])
              : classTeacherUid;
          if (recTeacherUid.isEmpty) return;
          final date = _safeString(rec['date']);
          if (date.isEmpty) return;
          final present = rec['present'] is Map
              ? Map<dynamic, dynamic>.from(rec['present'] as Map)
              : <dynamic, dynamic>{};
          final absent = rec['absent'] is Map
              ? Map<dynamic, dynamic>.from(rec['absent'] as Map)
              : <dynamic, dynamic>{};
          final learnerUids = <String>{
            ...present.keys.map((k) => k.toString().trim()),
            ...absent.keys.map((k) => k.toString().trim()),
          }..removeWhere((uid) => uid.isEmpty);
          for (final learnerUid in learnerUids) {
            final isPresent = present.containsKey(learnerUid);
            if (variant == 'private' && !isPresent) continue;
            addAttendance(
              teacherUid: recTeacherUid,
              learnerUid: learnerUid,
              option: _AttendanceOption(
                id: sessionKey.toString(),
                date: date,
                sortMs: _sortMsFromYmd(date),
                label:
                    '$date • ${variant == 'private' ? 'private' : 'in-class'} • ${isPresent ? 'present' : 'absent'}',
                source: variant,
                courseId: _safeString(rec['course_id'] ?? cls['course_id']),
                courseTitle: _safeString(
                  rec['course_title'] ?? cls['course_title'] ?? cls['title'],
                ),
                present: isPresent,
              ),
            );
          }
        });
      });
    }

    if (bookingProgressRaw is Map) {
      bookingProgressRaw.forEach((learnerKey, learnerProgressValue) {
        final learnerUid = learnerKey.toString().trim();
        if (learnerUid.isEmpty || learnerProgressValue is! Map) return;
        final learnerProgress = Map<dynamic, dynamic>.from(
          learnerProgressValue,
        );
        learnerProgress.forEach((courseKey, courseValue) {
          if (courseValue is! Map) return;
          final course = courseValue
              .map((k, v) => MapEntry(k.toString(), v))
              .cast<String, dynamic>();
          final attendance = course['online_attendance'];
          if (attendance is! Map) return;
          attendance.forEach((bookingKey, bookingValue) {
            if (bookingValue is! Map) return;
            final rec = bookingValue
                .map((k, v) => MapEntry(k.toString(), v))
                .cast<String, dynamic>();
            if (!_flexConsumesCredit(rec)) return;
            final teacherUid = _safeString(
              rec['teacherUid'] ?? rec['teacherId'],
            );
            if (teacherUid.isEmpty) return;
            final startAt = _asInt(rec['startAt']);
            final date = _safeString(rec['dayKey']).isNotEmpty
                ? _safeString(rec['dayKey'])
                : _ymdFromMs(startAt);
            if (date.isEmpty) return;
            final present =
                _asBool(rec['present']) ||
                _safeString(rec['status']).toLowerCase() == 'present';
            addAttendance(
              teacherUid: teacherUid,
              learnerUid: learnerUid,
              option: _AttendanceOption(
                id: bookingKey.toString(),
                date: date,
                sortMs: startAt > 0 ? startAt : _sortMsFromYmd(date),
                label:
                    '$date${_safeString(rec['time']).isEmpty ? '' : ' ${_safeString(rec['time'])}'} • flexible • ${present ? 'present' : 'credit'}',
                source: 'flexible',
                courseId: _safeString(rec['courseId'] ?? courseKey),
                courseTitle: _safeString(rec['courseTitle'] ?? course['title']),
                present: present,
              ),
            );
          });
        });
      });
    }

    final teachers = people.values.where((p) => _isTeacherRole(p.role)).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    final learnerLists = <String, List<_PersonInfo>>{};
    final groupsByTeacher = <String, List<_LearnerGroup>>{};
    for (final teacher in teachers) {
      final uids = learnerUidsByTeacher[teacher.uid] ?? <String>{};
      final learners =
          uids.map((uid) {
            return people[uid] ??
                _PersonInfo(
                  uid: uid,
                  name: uid,
                  serial: '',
                  role: 'learner',
                  photoUrl: '',
                  fallbackLevel: '',
                );
          }).toList()..sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          );
      learnerLists[teacher.uid] = learners;

      final classGroups = (classGroupsByTeacher[teacher.uid] ?? {}).values
          .toList();
      for (final group in classGroups) {
        group.learners.sort(
          (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        );
      }
      classGroups.sort(
        (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
      );

      final groupedUids = <String>{};
      for (final group in classGroups) {
        groupedUids.addAll(group.learners.map((l) => l.uid));
      }
      final ungrouped = learners
          .where((l) => !groupedUids.contains(l.uid))
          .toList();
      final levelBuckets = <String, List<_PersonInfo>>{};
      for (final learner in ungrouped) {
        final level = learner.fallbackLevel.trim().isEmpty
            ? 'No level'
            : learner.fallbackLevel.trim();
        levelBuckets.putIfAbsent(level, () => <_PersonInfo>[]).add(learner);
      }
      final levelGroups =
          levelBuckets.entries.map((entry) {
            final list = entry.value
              ..sort(
                (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
              );
            return _LearnerGroup(
              id: 'level|${entry.key}',
              title: 'Level: ${entry.key}',
              subtitle: 'No class group found',
              kind: 'level',
              learners: list,
            );
          }).toList()..sort(
            (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
          );
      groupsByTeacher[teacher.uid] = [...classGroups, ...levelGroups];
    }

    for (final list in attendanceByTeacherLearner.values) {
      final seen = <String>{};
      list.removeWhere(
        (opt) => !seen.add('${opt.source}|${opt.id}|${opt.date}'),
      );
      list.sort((a, b) {
        final byDate = a.sortMs.compareTo(b.sortMs);
        if (byDate != 0) return byDate;
        return a.label.compareTo(b.label);
      });
    }

    return _WageSourceData(
      teachers: teachers,
      learnersByTeacher: learnerLists,
      attendanceByTeacherLearner: attendanceByTeacherLearner,
      groupsByTeacher: groupsByTeacher,
    );
  }

  static Map<String, Map<String, _WageLog>> _parseLogs(dynamic raw) {
    final out = <String, Map<String, _WageLog>>{};
    if (raw is! Map) return out;
    raw.forEach((teacherKey, teacherValue) {
      final teacherUid = teacherKey.toString().trim();
      if (teacherUid.isEmpty || teacherValue is! Map) return;
      final teacherNode = Map<dynamic, dynamic>.from(teacherValue);
      teacherNode.forEach((learnerKey, learnerValue) {
        final learnerUid = learnerKey.toString().trim();
        if (learnerUid.isEmpty || learnerValue is! Map) return;
        final learnerNode = Map<dynamic, dynamic>.from(learnerValue);
        learnerNode.forEach((logKey, logValue) {
          if (logValue is! Map) return;
          final id = logKey.toString().trim();
          if (id.isEmpty) return;
          final map = logValue
              .map((k, v) => MapEntry(k.toString(), v))
              .cast<String, dynamic>();
          out.putIfAbsent(
            _pairKey(teacherUid, learnerUid),
            () => <String, _WageLog>{},
          )[id] = _WageLog.fromMap(
            id,
            map,
          );
        });
      });
    });
    return out;
  }

  static Map<String, Map<String, _WageLog>> _parseTeacherLogs(
    String teacherUid,
    dynamic raw,
  ) {
    final out = <String, Map<String, _WageLog>>{};
    final teacher = teacherUid.trim();
    if (teacher.isEmpty || raw is! Map) return out;
    final teacherNode = Map<dynamic, dynamic>.from(raw);
    teacherNode.forEach((learnerKey, learnerValue) {
      final learnerUid = learnerKey.toString().trim();
      if (learnerUid.isEmpty || learnerValue is! Map) return;
      final learnerNode = Map<dynamic, dynamic>.from(learnerValue);
      learnerNode.forEach((logKey, logValue) {
        if (logValue is! Map) return;
        final id = logKey.toString().trim();
        if (id.isEmpty) return;
        final map = logValue
            .map((k, v) => MapEntry(k.toString(), v))
            .cast<String, dynamic>();
        out.putIfAbsent(
          _pairKey(teacher, learnerUid),
          () => <String, _WageLog>{},
        )[id] = _WageLog.fromMap(
          id,
          map,
        );
      });
    });
    return out;
  }

  static String _pairKey(String teacherUid, String learnerUid) =>
      '${teacherUid.trim()}|${learnerUid.trim()}';

  Future<void> _openTeacher(_PersonInfo teacher, _WageSourceData source) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _TeacherWageDetailScreen(
          teacher: teacher,
          groups:
              source.groupsByTeacher[teacher.uid] ?? const <_LearnerGroup>[],
          attendanceByPair: source.attendanceByTeacherLearner,
          onAddOrEditLog: _showWageLogDialog,
          onDeleteLog: _deleteLog,
        ),
      ),
    );
  }

  Future<void> _showWageLogDialog({
    required _PersonInfo teacher,
    required _PersonInfo learner,
    required List<_AttendanceOption> attendanceOptions,
    _WageLog? existing,
  }) async {
    final sessionsC = TextEditingController(
      text: existing == null ? '' : existing.sessionCount.toString(),
    );
    final amountC = TextEditingController(
      text: existing == null ? '' : existing.amount.toString(),
    );
    final percentC = TextEditingController(
      text: existing == null ? '100' : existing.teacherPercent.toString(),
    );
    var startDate =
        existing?.startDate ??
        (attendanceOptions.isNotEmpty ? attendanceOptions.first.date : '');
    var endDate =
        existing?.endDate ??
        (attendanceOptions.isNotEmpty ? attendanceOptions.last.date : '');

    try {
      final saved = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogCtx) {
          return StatefulBuilder(
            builder: (context, setD) {
              final amount = _asInt(amountC.text);
              final percent = _asInt(percentC.text).clamp(0, 100);
              final teacherNet = ((amount * percent) / 100).round();
              final schoolNet = (amount - teacherNet).clamp(0, amount);
              final dateValues = attendanceOptions
                  .map((e) => e.date)
                  .toSet()
                  .toList();
              if (startDate.isNotEmpty && !dateValues.contains(startDate))
                dateValues.add(startDate);
              if (endDate.isNotEmpty && !dateValues.contains(endDate))
                dateValues.add(endDate);
              dateValues.sort();

              Widget dateDropdown({
                required String label,
                required String value,
                required ValueChanged<String> onChanged,
              }) {
                if (dateValues.isEmpty) {
                  return TextFormField(
                    initialValue: value,
                    decoration: InputDecoration(
                      labelText: label,
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: onChanged,
                  );
                }
                return DropdownButtonFormField<String>(
                  initialValue: value.isNotEmpty && dateValues.contains(value)
                      ? value
                      : dateValues.first,
                  decoration: InputDecoration(
                    labelText: label,
                    border: const OutlineInputBorder(),
                  ),
                  items: dateValues
                      .map((d) => DropdownMenuItem(value: d, child: Text(d)))
                      .toList(),
                  onChanged: (v) => setD(() => onChanged(v ?? '')),
                );
              }

              return AlertDialog(
                title: Text(
                  existing == null ? 'Add wage log' : 'Edit wage log',
                ),
                content: SizedBox(
                  width: 560,
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${learner.name} • ${teacher.name}',
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            color: AdminWagesScreen.primaryBlue,
                          ),
                        ),
                        const SizedBox(height: 12),
                        if (attendanceOptions.isEmpty)
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: Colors.orange.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: Colors.orange.withValues(alpha: 0.35),
                              ),
                            ),
                            child: const Text(
                              'No in-class/private/flexible attendance found for this learner and teacher. Dates can still be typed manually.',
                              style: TextStyle(fontWeight: FontWeight.w700),
                            ),
                          ),
                        if (attendanceOptions.isEmpty)
                          const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: dateDropdown(
                                label: 'From date',
                                value: startDate,
                                onChanged: (v) => startDate = v,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: dateDropdown(
                                label: 'To date',
                                value: endDate,
                                onChanged: (v) => endDate = v,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: sessionsC,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                  labelText: 'Number of sessions',
                                  border: OutlineInputBorder(),
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: TextField(
                                controller: amountC,
                                keyboardType: TextInputType.number,
                                onChanged: (_) => setD(() {}),
                                decoration: const InputDecoration(
                                  labelText: 'Amount',
                                  suffixText: 'DA',
                                  border: OutlineInputBorder(),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: percentC,
                          keyboardType: TextInputType.number,
                          onChanged: (_) => setD(() {}),
                          decoration: const InputDecoration(
                            labelText: 'Teacher percentage',
                            suffixText: '%',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            _pill('Teacher: $teacherNet DA', Colors.green),
                            _pill(
                              'School: $schoolNet DA',
                              AdminWagesScreen.primaryBlue,
                            ),
                            _pill(
                              'Attendance dates: ${attendanceOptions.length}',
                              Colors.blueGrey,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(dialogCtx).pop(false),
                    child: const Text('Cancel'),
                  ),
                  FilledButton.icon(
                    icon: Icon(
                      existing == null ? Icons.add_rounded : Icons.edit_rounded,
                    ),
                    label: Text(existing == null ? 'Add log' : 'Save'),
                    onPressed: () async {
                      final sessions = _asInt(sessionsC.text);
                      final amount = _asInt(amountC.text);
                      final pct = _asInt(percentC.text).clamp(0, 100);
                      if (sessions <= 0 ||
                          amount <= 0 ||
                          pct <= 0 ||
                          startDate.trim().isEmpty ||
                          endDate.trim().isEmpty) {
                        AppToast.fromSnackBar(
                          context,
                          const SnackBar(
                            content: Text(
                              'Fill sessions, amount, percentage, start date, and end date.',
                            ),
                          ),
                        );
                        return;
                      }
                      final ok =
                          await showDialog<bool>(
                            context: context,
                            builder: (_) => AlertDialog(
                              title: Text(
                                existing == null
                                    ? 'Add this log?'
                                    : 'Save changes?',
                              ),
                              content: Text(
                                '${learner.name}\n$startDate to $endDate\n$sessions sessions • $amount DA • $pct%',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () =>
                                      Navigator.pop(context, false),
                                  child: const Text('Cancel'),
                                ),
                                FilledButton(
                                  onPressed: () => Navigator.pop(context, true),
                                  child: const Text('Confirm'),
                                ),
                              ],
                            ),
                          ) ??
                          false;
                      if (!ok) return;

                      final selectedSessionIds = attendanceOptions
                          .where(
                            (a) =>
                                a.date.compareTo(startDate) >= 0 &&
                                a.date.compareTo(endDate) <= 0,
                          )
                          .map((a) => a.id)
                          .toList();
                      final teacherNet = ((amount * pct) / 100).round();
                      final schoolNet = (amount - teacherNet).clamp(0, amount);
                      final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
                      final ref = existing == null
                          ? _db
                                .child(
                                  'teacher_wage_logs/${teacher.uid}/${learner.uid}',
                                )
                                .push()
                          : _db.child(
                              'teacher_wage_logs/${teacher.uid}/${learner.uid}/${existing.id}',
                            );
                      await ref.update({
                        'teacherUid': teacher.uid,
                        'teacherName': teacher.name,
                        'learnerUid': learner.uid,
                        'learnerName': learner.name,
                        'learnerSerial': learner.serial,
                        'sessionCount': sessions,
                        'startDate': startDate.trim(),
                        'endDate': endDate.trim(),
                        'amount': amount,
                        'teacherPercent': pct,
                        'teacherNet': teacherNet,
                        'schoolNet': schoolNet,
                        'attendanceSessionIds': selectedSessionIds,
                        'updatedAt': ServerValue.timestamp,
                        'updatedBy': uid,
                        if (existing == null)
                          'createdAt': ServerValue.timestamp,
                        if (existing == null) 'createdBy': uid,
                      });
                      if (dialogCtx.mounted) Navigator.of(dialogCtx).pop(true);
                    },
                  ),
                ],
              );
            },
          );
        },
      );
      if (saved == true && mounted) {
        AppToast.fromSnackBar(
          context,
          SnackBar(
            content: Text(
              existing == null ? 'Wage log added.' : 'Wage log updated.',
            ),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      AppToast.fromSnackBar(
        context,
        SnackBar(
          content: Text(toHumanError(e, fallback: 'Could not save wage log.')),
        ),
      );
    } finally {
      sessionsC.dispose();
      amountC.dispose();
      percentC.dispose();
    }
  }

  Future<void> _deleteLog({
    required _PersonInfo teacher,
    required _PersonInfo learner,
    required _WageLog log,
  }) async {
    final ok =
        await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Delete wage log?'),
            content: Text(
              'Delete ${learner.name}\'s log from ${log.startDate} to ${log.endDate}?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Colors.red),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        ) ??
        false;
    if (!ok) return;
    try {
      await _db
          .child('teacher_wage_logs/${teacher.uid}/${learner.uid}/${log.id}')
          .remove();
      if (!mounted) return;
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('Wage log deleted.')),
      );
    } catch (e) {
      if (!mounted) return;
      AppToast.fromSnackBar(
        context,
        SnackBar(
          content: Text(
            toHumanError(e, fallback: 'Could not delete wage log.'),
          ),
        ),
      );
    }
  }

  static Widget _pill(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w900,
          fontSize: 12,
        ),
      ),
    );
  }

  static bool _matches(String text, String query) {
    if (query.isEmpty) return true;
    return text.toLowerCase().contains(query);
  }

  static bool _teacherMatchesSearch({
    required _PersonInfo teacher,
    required List<_PersonInfo> learners,
    required String query,
  }) {
    if (query.isEmpty) return true;
    final teacherHaystack = [
      teacher.name,
      teacher.serial,
      teacher.uid,
    ].join(' ');
    if (_matches(teacherHaystack, query)) return true;
    for (final learner in learners) {
      final learnerHaystack = [
        learner.name,
        learner.serial,
        learner.uid,
      ].join(' ');
      if (_matches(learnerHaystack, query)) return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AdminWagesScreen.appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0,
        title: const Text(
          'Wages',
          style: TextStyle(
            color: AdminWagesScreen.primaryBlue,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
      body: adminWebBodyFrame(
        context: context,
        maxWidth: 1500,
        child: StreamBuilder<DatabaseEvent>(
          stream: _db.child('users').onValue,
          builder: (context, usersSnap) {
            if (usersSnap.hasError)
              return const Center(child: Text('Could not load users.'));
            if (!usersSnap.hasData)
              return const Center(child: CircularProgressIndicator());
            final people = _parsePeople(usersSnap.data?.snapshot.value);
            return StreamBuilder<DatabaseEvent>(
              stream: _db.child('classes').onValue,
              builder: (context, classesSnap) {
                if (classesSnap.hasError)
                  return const Center(child: Text('Could not load classes.'));
                if (!classesSnap.hasData)
                  return const Center(child: CircularProgressIndicator());
                return StreamBuilder<DatabaseEvent>(
                  stream: _db.child('booking_progress').onValue,
                  builder: (context, bookingSnap) {
                    final source = _buildSourceData(
                      people: people,
                      classesRaw: classesSnap.data?.snapshot.value,
                      bookingProgressRaw: bookingSnap.data?.snapshot.value,
                    );
                    return StreamBuilder<DatabaseEvent>(
                      stream: _db.child('teacher_wage_logs').onValue,
                      builder: (context, logsSnap) {
                        final logs = _parseLogs(logsSnap.data?.snapshot.value);
                        final teachers = source.teachers.where((teacher) {
                          final learners =
                              source.learnersByTeacher[teacher.uid] ??
                              const <_PersonInfo>[];
                          return _teacherMatchesSearch(
                            teacher: teacher,
                            learners: learners,
                            query: _search,
                          );
                        }).toList();
                        if (teachers.isEmpty) {
                          return Column(
                            children: [
                              _SearchBox(
                                controller: _searchC,
                                hint: 'Search teacher or learner...',
                              ),
                              const Expanded(
                                child: Center(
                                  child: Text('No teachers found.'),
                                ),
                              ),
                            ],
                          );
                        }
                        return Column(
                          children: [
                            _SearchBox(
                              controller: _searchC,
                              hint: 'Search teacher or learner...',
                            ),
                            Expanded(
                              child: GridView.builder(
                                padding: const EdgeInsets.fromLTRB(
                                  12,
                                  0,
                                  12,
                                  24,
                                ),
                                gridDelegate:
                                    SliverGridDelegateWithFixedCrossAxisCount(
                                      crossAxisCount: 2,
                                      mainAxisSpacing: 10,
                                      crossAxisSpacing: 10,
                                      childAspectRatio: 2.25,
                                    ),
                                itemCount: teachers.length,
                                itemBuilder: (context, i) {
                                  final teacher = teachers[i];
                                  final learners =
                                      source.learnersByTeacher[teacher.uid] ??
                                      const <_PersonInfo>[];
                                  var logCount = 0;
                                  var teacherNet = 0;
                                  for (final learner in learners) {
                                    final bucket =
                                        logs[_pairKey(
                                          teacher.uid,
                                          learner.uid,
                                        )] ??
                                        const <String, _WageLog>{};
                                    logCount += bucket.length;
                                    teacherNet += bucket.values.fold<int>(
                                      0,
                                      (sum, log) => sum + log.teacherNet,
                                    );
                                  }
                                  return _TeacherCard(
                                    teacher: teacher,
                                    learnerCount: learners.length,
                                    logCount: logCount,
                                    teacherNet: teacherNet,
                                    onTap: () => _openTeacher(teacher, source),
                                  );
                                },
                              ),
                            ),
                          ],
                        );
                      },
                    );
                  },
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _TeacherWageDetailScreen extends StatefulWidget {
  const _TeacherWageDetailScreen({
    required this.teacher,
    required this.groups,
    required this.attendanceByPair,
    required this.onAddOrEditLog,
    required this.onDeleteLog,
  });

  final _PersonInfo teacher;
  final List<_LearnerGroup> groups;
  final Map<String, List<_AttendanceOption>> attendanceByPair;
  final Future<void> Function({
    required _PersonInfo teacher,
    required _PersonInfo learner,
    required List<_AttendanceOption> attendanceOptions,
    _WageLog? existing,
  })
  onAddOrEditLog;
  final Future<void> Function({
    required _PersonInfo teacher,
    required _PersonInfo learner,
    required _WageLog log,
  })
  onDeleteLog;

  @override
  State<_TeacherWageDetailScreen> createState() =>
      _TeacherWageDetailScreenState();
}

class _TeacherWageDetailScreenState extends State<_TeacherWageDetailScreen> {
  final TextEditingController _searchC = TextEditingController();
  String _search = '';

  @override
  void initState() {
    super.initState();
    _searchC.addListener(() {
      if (!mounted) return;
      setState(() => _search = _searchC.text.trim().toLowerCase());
    });
  }

  @override
  void dispose() {
    _searchC.dispose();
    super.dispose();
  }

  List<_PersonInfo> get _uniqueLearners {
    final byUid = <String, _PersonInfo>{};
    for (final group in widget.groups) {
      for (final learner in group.learners) {
        byUid[learner.uid] = learner;
      }
    }
    return byUid.values.toList();
  }

  List<_LearnerGroup> _filteredGroups() {
    if (_search.isEmpty) return widget.groups;
    final out = <_LearnerGroup>[];
    for (final group in widget.groups) {
      final groupText = '${group.title} ${group.subtitle} ${group.kind}'
          .toLowerCase();
      if (groupText.contains(_search)) {
        out.add(group);
        continue;
      }
      final learners = group.learners.where((learner) {
        final text = '${learner.name} ${learner.serial} ${learner.uid}'
            .toLowerCase();
        return text.contains(_search);
      }).toList();
      if (learners.isNotEmpty) {
        out.add(
          _LearnerGroup(
            id: group.id,
            title: group.title,
            subtitle: group.subtitle,
            kind: group.kind,
            learners: learners,
          ),
        );
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AdminWagesScreen.appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        title: Text(
          widget.teacher.name,
          style: const TextStyle(
            color: AdminWagesScreen.primaryBlue,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
      body: adminWebBodyFrame(
        context: context,
        maxWidth: 1200,
        child: StreamBuilder<DatabaseEvent>(
          stream: FirebaseDatabase.instance
              .ref('teacher_wage_logs/${widget.teacher.uid}')
              .onValue,
          builder: (context, snap) {
            final logs = _AdminWagesScreenState._parseTeacherLogs(
              widget.teacher.uid,
              snap.data?.snapshot.value,
            );
            final uniqueLearners = _uniqueLearners;
            var totalLogs = 0;
            var totalNet = 0;
            for (final learner in uniqueLearners) {
              final bucket =
                  logs[_AdminWagesScreenState._pairKey(
                    widget.teacher.uid,
                    learner.uid,
                  )] ??
                  const <String, _WageLog>{};
              totalLogs += bucket.length;
              totalNet += bucket.values.fold<int>(
                0,
                (sum, log) => sum + log.teacherNet,
              );
            }
            final groups = _filteredGroups();
            return Column(
              children: [
                Container(
                  margin: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: AdminWagesScreen.uiBorder),
                  ),
                  child: Row(
                    children: [
                      ProfileAvatar(
                        name: widget.teacher.name,
                        photoUrl: widget.teacher.photoUrl,
                        radius: 34,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.teacher.name,
                              style: const TextStyle(
                                fontWeight: FontWeight.w900,
                                color: AdminWagesScreen.primaryBlue,
                                fontSize: 18,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                _AdminWagesScreenState._pill(
                                  'Learners: ${uniqueLearners.length}',
                                  AdminWagesScreen.primaryBlue,
                                ),
                                _AdminWagesScreenState._pill(
                                  'Groups: ${widget.groups.length}',
                                  Colors.blueGrey,
                                ),
                                _AdminWagesScreenState._pill(
                                  'Logs: $totalLogs',
                                  Colors.blueGrey,
                                ),
                                _AdminWagesScreenState._pill(
                                  'Teacher net: $totalNet DA',
                                  Colors.green,
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                _SearchBox(
                  controller: _searchC,
                  hint: 'Search learners, class, or level...',
                ),
                Expanded(
                  child: groups.isEmpty
                      ? const Center(child: Text('No learners found.'))
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                          itemCount: groups.length,
                          itemBuilder: (context, i) => _LearnerGroupSection(
                            group: groups[i],
                            teacher: widget.teacher,
                            logsByPair: logs,
                            attendanceByPair: widget.attendanceByPair,
                            onAddOrEditLog: widget.onAddOrEditLog,
                            onDeleteLog: widget.onDeleteLog,
                          ),
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _LearnerGroupSection extends StatefulWidget {
  const _LearnerGroupSection({
    required this.group,
    required this.teacher,
    required this.logsByPair,
    required this.attendanceByPair,
    required this.onAddOrEditLog,
    required this.onDeleteLog,
  });

  final _LearnerGroup group;
  final _PersonInfo teacher;
  final Map<String, Map<String, _WageLog>> logsByPair;
  final Map<String, List<_AttendanceOption>> attendanceByPair;
  final Future<void> Function({
    required _PersonInfo teacher,
    required _PersonInfo learner,
    required List<_AttendanceOption> attendanceOptions,
    _WageLog? existing,
  })
  onAddOrEditLog;
  final Future<void> Function({
    required _PersonInfo teacher,
    required _PersonInfo learner,
    required _WageLog log,
  })
  onDeleteLog;

  @override
  State<_LearnerGroupSection> createState() => _LearnerGroupSectionState();
}

class _LearnerGroupSectionState extends State<_LearnerGroupSection> {
  bool _expanded = true;

  void _showClassInfo() {
    final classData = widget.group.classData;
    if (classData == null) {
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Class info'),
          content: const Text('This group is not associated with a class.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }

    final lines = <String>[];
    if ((classData['class_id'] ?? '').toString().trim().isNotEmpty) {
      lines.add('Class ID: ${classData['class_id']}');
    }
    if ((classData['course_code'] ?? '').toString().trim().isNotEmpty) {
      lines.add('Course code: ${classData['course_code']}');
    }
    if ((classData['course_title'] ?? '').toString().trim().isNotEmpty) {
      lines.add('Course: ${classData['course_title']}');
    }
    final level = (classData['course_level'] ?? classData['level'] ?? '')
        .toString()
        .trim();
    if (level.isNotEmpty) {
      lines.add('Level: $level');
    }
    final variant = _AdminWagesScreenState._variantLabel(
      _AdminWagesScreenState._safeString(
        classData['variantKey'] ?? classData['variant'],
      ),
    );
    lines.add('Delivery: $variant');

    final schedule = classData['schedule'];
    if (schedule is String && schedule.trim().isNotEmpty) {
      lines.add('Schedule: $schedule');
    } else if (schedule is Map && schedule.isNotEmpty) {
      final parts = schedule.entries
          .map((e) => '${e.key}: ${e.value}')
          .toList();
      lines.add('Schedule: ${parts.join(', ')}');
    }

    final days = classData['days'];
    if (days is String && days.trim().isNotEmpty) {
      lines.add('Days: $days');
    } else if (days is List && days.isNotEmpty) {
      lines.add('Days: ${days.join(', ')}');
    }

    final time = classData['time'];
    if (time is String && time.trim().isNotEmpty) {
      lines.add('Time: $time');
    }

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Class details'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (lines.isEmpty)
              const Text('No additional class data available.')
            else
              for (final line in lines)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    line,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 2),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: AdminWagesScreen.uiBorder.withValues(alpha: 0.9),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  Icon(
                    widget.group.kind == 'class'
                        ? Icons.groups_2_rounded
                        : Icons.school_rounded,
                    color: AdminWagesScreen.primaryBlue,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.group.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AdminWagesScreen.primaryBlue,
                            fontWeight: FontWeight.w900,
                            fontSize: 14,
                          ),
                        ),
                        if (widget.group.subtitle.isNotEmpty)
                          Text(
                            widget.group.subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.black.withValues(alpha: 0.6),
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                            ),
                          ),
                      ],
                    ),
                  ),
                  _AdminWagesScreenState._pill(
                    '${widget.group.learners.length} learners',
                    widget.group.kind == 'class'
                        ? AdminWagesScreen.primaryBlue
                        : Colors.blueGrey,
                  ),
                  if (widget.group.classData != null)
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: IconButton(
                        tooltip: 'Class details',
                        icon: const Icon(Icons.info_outline_rounded, size: 20),
                        color: AdminWagesScreen.primaryBlue,
                        onPressed: _showClassInfo,
                      ),
                    ),
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    color: AdminWagesScreen.primaryBlue,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) ...[
            const SizedBox(height: 8),
            for (final learner in widget.group.learners)
              Builder(
                builder: (context) {
                  final pairKey = _AdminWagesScreenState._pairKey(
                    widget.teacher.uid,
                    learner.uid,
                  );
                  final attendance =
                      widget.attendanceByPair[pairKey] ??
                      const <_AttendanceOption>[];
                  final logs =
                      (widget.logsByPair[pairKey] ?? const <String, _WageLog>{})
                          .values
                          .toList()
                        ..sort((a, b) => b.sortKey.compareTo(a.sortKey));
                  return _LearnerWageCard(
                    teacher: widget.teacher,
                    learner: learner,
                    attendanceOptions: attendance,
                    logs: logs,
                    onAdd: () => widget.onAddOrEditLog(
                      teacher: widget.teacher,
                      learner: learner,
                      attendanceOptions: attendance,
                    ),
                    onEdit: (log) => widget.onAddOrEditLog(
                      teacher: widget.teacher,
                      learner: learner,
                      attendanceOptions: attendance,
                      existing: log,
                    ),
                    onDelete: (log) => widget.onDeleteLog(
                      teacher: widget.teacher,
                      learner: learner,
                      log: log,
                    ),
                  );
                },
              ),
          ],
        ],
      ),
    );
  }
}

class _SearchBox extends StatelessWidget {
  const _SearchBox({required this.controller, required this.hint});

  final TextEditingController controller;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
      child: TextField(
        controller: controller,
        decoration: InputDecoration(
          hintText: hint,
          prefixIcon: const Icon(Icons.search_rounded),
          suffixIcon: controller.text.trim().isEmpty
              ? null
              : IconButton(
                  tooltip: 'Clear search',
                  icon: const Icon(Icons.close_rounded),
                  onPressed: controller.clear,
                ),
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: AdminWagesScreen.uiBorder),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: AdminWagesScreen.uiBorder),
          ),
        ),
      ),
    );
  }
}

class _TeacherCard extends StatelessWidget {
  const _TeacherCard({
    required this.teacher,
    required this.learnerCount,
    required this.logCount,
    required this.teacherNet,
    required this.onTap,
  });

  final _PersonInfo teacher;
  final int learnerCount;
  final int logCount;
  final int teacherNet;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: AdminWagesScreen.uiBorder.withValues(alpha: 0.85),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.035),
              blurRadius: 12,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          children: [
            ProfileAvatar(
              name: teacher.name,
              photoUrl: teacher.photoUrl,
              radius: 30,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    teacher.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      color: AdminWagesScreen.primaryBlue,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 5,
                    children: [
                      _AdminWagesScreenState._pill(
                        '$learnerCount learners',
                        AdminWagesScreen.primaryBlue,
                      ),
                      _AdminWagesScreenState._pill(
                        '$logCount logs',
                        Colors.blueGrey,
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Text(
                    '$teacherNet DA',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.black.withValues(alpha: 0.62),
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
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
}

class _LearnerWageCard extends StatelessWidget {
  const _LearnerWageCard({
    required this.teacher,
    required this.learner,
    required this.attendanceOptions,
    required this.logs,
    required this.onAdd,
    required this.onEdit,
    required this.onDelete,
  });

  final _PersonInfo teacher;
  final _PersonInfo learner;
  final List<_AttendanceOption> attendanceOptions;
  final List<_WageLog> logs;
  final VoidCallback onAdd;
  final ValueChanged<_WageLog> onEdit;
  final ValueChanged<_WageLog> onDelete;

  @override
  Widget build(BuildContext context) {
    final totalNet = logs.fold<int>(0, (sum, log) => sum + log.teacherNet);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: AdminWagesScreen.uiBorder.withValues(alpha: 0.85),
        ),
      ),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        leading: ProfileAvatar(
          name: learner.name,
          photoUrl: learner.photoUrl,
          radius: 22,
        ),
        title: Text(
          learner.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontWeight: FontWeight.w900,
            color: AdminWagesScreen.primaryBlue,
          ),
        ),
        subtitle: Text(
          [
            if (learner.serial.isNotEmpty) learner.serial,
            '${attendanceOptions.length} attendance dates',
            '${logs.length} logs',
            '$totalNet DA',
          ].join(' • '),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: Colors.black.withValues(alpha: 0.62),
          ),
        ),
        trailing: IconButton(
          tooltip: 'Add wage log',
          icon: const Icon(
            Icons.payments_rounded,
            color: AdminWagesScreen.actionOrange,
          ),
          onPressed: onAdd,
        ),
        children: [
          if (logs.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AdminWagesScreen.appBg,
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Text(
                'No wage logs yet. Tap the cash icon to add one.',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
            )
          else
            for (final log in logs) ...[
              _WageLogRow(
                log: log,
                onEdit: () => onEdit(log),
                onDelete: () => onDelete(log),
              ),
              const SizedBox(height: 8),
            ],
        ],
      ),
    );
  }
}

class _WageLogRow extends StatelessWidget {
  const _WageLogRow({
    required this.log,
    required this.onEdit,
    required this.onDelete,
  });

  final _WageLog log;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: AdminWagesScreen.appBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: AdminWagesScreen.uiBorder.withValues(alpha: 0.7),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Text(
              '${log.startDate} -> ${log.endDate}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 12,
                color: AdminWagesScreen.primaryBlue,
              ),
            ),
          ),
          Expanded(
            child: Text(
              '${log.sessionCount}',
              maxLines: 1,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 12,
                color: Colors.blueGrey,
              ),
            ),
          ),
          Expanded(
            child: Text(
              '${log.amount} DA',
              maxLines: 1,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 12,
                color: Colors.black87,
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              '${log.teacherPercent}% = ${log.teacherNet} DA',
              maxLines: 1,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 12,
                color: Colors.green,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Edit',
            onPressed: onEdit,
            icon: const Icon(
              Icons.edit_rounded,
              color: AdminWagesScreen.actionOrange,
              size: 20,
            ),
          ),
          IconButton(
            tooltip: 'Delete',
            onPressed: onDelete,
            icon: const Icon(
              Icons.delete_outline_rounded,
              color: Colors.red,
              size: 20,
            ),
          ),
        ],
      ),
    );
  }
}

class _WageSourceData {
  const _WageSourceData({
    required this.teachers,
    required this.learnersByTeacher,
    required this.attendanceByTeacherLearner,
    required this.groupsByTeacher,
  });

  final List<_PersonInfo> teachers;
  final Map<String, List<_PersonInfo>> learnersByTeacher;
  final Map<String, List<_AttendanceOption>> attendanceByTeacherLearner;
  final Map<String, List<_LearnerGroup>> groupsByTeacher;
}

class _LearnerGroup {
  const _LearnerGroup({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.kind,
    required this.learners,
    this.classData,
  });

  final String id;
  final String title;
  final String subtitle;
  final String kind;
  final List<_PersonInfo> learners;
  final Map<String, dynamic>? classData;
}

class _PersonInfo {
  const _PersonInfo({
    required this.uid,
    required this.name,
    required this.serial,
    required this.role,
    required this.photoUrl,
    required this.fallbackLevel,
  });

  final String uid;
  final String name;
  final String serial;
  final String role;
  final String photoUrl;
  final String fallbackLevel;
}

class _AttendanceOption {
  const _AttendanceOption({
    required this.id,
    required this.date,
    required this.sortMs,
    required this.label,
    required this.source,
    required this.courseId,
    required this.courseTitle,
    required this.present,
  });

  final String id;
  final String date;
  final int sortMs;
  final String label;
  final String source;
  final String courseId;
  final String courseTitle;
  final bool present;
}

class _WageLog {
  const _WageLog({
    required this.id,
    required this.sessionCount,
    required this.startDate,
    required this.endDate,
    required this.amount,
    required this.teacherPercent,
    required this.teacherNet,
    required this.schoolNet,
    required this.updatedAt,
  });

  final String id;
  final int sessionCount;
  final String startDate;
  final String endDate;
  final int amount;
  final int teacherPercent;
  final int teacherNet;
  final int schoolNet;
  final int updatedAt;

  int get sortKey => updatedAt > 0
      ? updatedAt
      : _AdminWagesScreenState._sortMsFromYmd(endDate);

  factory _WageLog.fromMap(String id, Map<String, dynamic> map) {
    final amount = _AdminWagesScreenState._asInt(map['amount']);
    final percent = _AdminWagesScreenState._asInt(
      map['teacherPercent'],
    ).clamp(0, 100);
    final teacherNet = _AdminWagesScreenState._asInt(map['teacherNet']) > 0
        ? _AdminWagesScreenState._asInt(map['teacherNet'])
        : ((amount * percent) / 100).round();
    return _WageLog(
      id: id,
      sessionCount: _AdminWagesScreenState._asInt(map['sessionCount']),
      startDate: _AdminWagesScreenState._safeString(map['startDate']),
      endDate: _AdminWagesScreenState._safeString(map['endDate']),
      amount: amount,
      teacherPercent: percent,
      teacherNet: teacherNet,
      schoolNet: _AdminWagesScreenState._asInt(map['schoolNet']) > 0
          ? _AdminWagesScreenState._asInt(map['schoolNet'])
          : (amount - teacherNet).clamp(0, amount),
      updatedAt: _AdminWagesScreenState._asInt(
        map['updatedAt'] ?? map['createdAt'],
      ),
    );
  }
}
