import 'package:firebase_database/firebase_database.dart';

class TeacherScheduleViewerIdentity {
  const TeacherScheduleViewerIdentity({
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

class TeacherScheduleOccurrence {
  const TeacherScheduleOccurrence({
    required this.classId,
    required this.courseCode,
    required this.courseTitle,
    required this.start,
    required this.end,
    required this.isOnline,
    required this.onlineBookingKey,
  });

  final String classId;
  final String courseCode;
  final String courseTitle;
  final DateTime start;
  final DateTime end;
  final bool isOnline;
  final String onlineBookingKey;

  String get notificationClassId {
    if (!isOnline) return classId;
    return 'online:$onlineBookingKey';
  }
}

class TeacherScheduleWidgetItem {
  const TeacherScheduleWidgetItem({
    required this.start,
    required this.end,
    required this.title,
    required this.isOnline,
  });

  final DateTime start;
  final DateTime end;
  final String title;
  final bool isOnline;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'start': start.toIso8601String(),
      'end': end.toIso8601String(),
      'title': title,
      'isOnline': isOnline,
    };
  }
}

class TeacherScheduleWidgetSnapshot {
  const TeacherScheduleWidgetSnapshot({
    required this.teacherName,
    required this.updatedAt,
    required this.items,
    required this.hasSignedInTeacher,
  });

  final String teacherName;
  final DateTime updatedAt;
  final List<TeacherScheduleWidgetItem> items;
  final bool hasSignedInTeacher;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'teacherName': teacherName,
      'updatedAt': updatedAt.toIso8601String(),
      'hasSignedInTeacher': hasSignedInTeacher,
      'items': items.map((e) => e.toJson()).toList(),
    };
  }
}

class TeacherScheduleDataService {
  TeacherScheduleDataService._();

  static String norm(String s) => s.trim().toLowerCase();

  static Future<TeacherScheduleViewerIdentity> loadViewerIdentity(
    String uid,
  ) async {
    if (uid.isEmpty) {
      return const TeacherScheduleViewerIdentity(
        uid: '',
        name: '',
        serial: '',
        isAdmin: false,
      );
    }

    try {
      final snap = await FirebaseDatabase.instance.ref('users/$uid').get();
      if (!snap.exists || snap.value is! Map) {
        return TeacherScheduleViewerIdentity(
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

      return TeacherScheduleViewerIdentity(
        uid: uid,
        name: ('$fn $ln').trim(),
        serial: (m['serial'] ?? '').toString().trim(),
        isAdmin: role == 'admin',
      );
    } catch (_) {
      return TeacherScheduleViewerIdentity(
        uid: uid,
        name: '',
        serial: '',
        isAdmin: false,
      );
    }
  }

  static bool matchesTeacherClass(
    Map<String, dynamic> classData, {
    required String teacherUid,
    required String teacherName,
    required String teacherSerial,
  }) {
    String curUid = '';
    String curName = '';
    String curSerial = '';

    final cur = classData['instructor_current'];
    if (cur is Map) {
      final curMap = Map<String, dynamic>.from(cur);
      curUid = (curMap['uid'] ?? '').toString().trim();
      curName = (curMap['name'] ?? '').toString().trim();
      curSerial = (curMap['serial'] ?? '').toString().trim();
    }

    final legacyInstructorName = (classData['instructor'] ?? '')
        .toString()
        .trim();

    final matchesUid = curUid.isNotEmpty && curUid == teacherUid;
    final matchesName =
        teacherName.isNotEmpty &&
        norm(
              legacyInstructorName.isNotEmpty ? legacyInstructorName : curName,
            ) ==
            norm(teacherName);

    final legacySerial =
        (classData['instructorserial'] ?? classData['serial'] ?? curSerial)
            .toString()
            .trim();
    final matchesSerial =
        teacherSerial.isNotEmpty && legacySerial == teacherSerial;

    return matchesUid || matchesName || matchesSerial;
  }

  static List<TeacherScheduleOccurrence> generateOccurrences(
    Map<String, dynamic> cls, {
    DateTime? now,
    Duration historyWindow = const Duration(days: 30),
    Duration horizonWindow = const Duration(days: 365),
  }) {
    if (cls['status']?.toString() != 'active') return const [];

    final schedule = (cls['schedule'] is Map)
        ? Map<String, dynamic>.from(cls['schedule'] as Map)
        : null;
    if (schedule == null) return const [];

    final firstDateRaw = schedule['first_session_date']?.toString() ?? '';
    final firstDate = DateTime.tryParse(firstDateRaw);
    if (firstDate == null) return const [];
    final firstDateDay = DateTime(
      firstDate.year,
      firstDate.month,
      firstDate.day,
    );

    final sessionsRaw = schedule['sessions'];
    final pattern = <Map<String, dynamic>>[];
    if (sessionsRaw is List) {
      for (final it in sessionsRaw) {
        if (it is! Map) continue;
        final row = Map<String, dynamic>.from(it);
        if (!row.containsKey('day') || !row.containsKey('start_time')) continue;
        pattern.add(row);
      }
    } else if (sessionsRaw is Map) {
      for (final it in sessionsRaw.values) {
        if (it is! Map) continue;
        final row = Map<String, dynamic>.from(it);
        if (!row.containsKey('day') || !row.containsKey('start_time')) continue;
        pattern.add(row);
      }
    }
    if (pattern.isEmpty) return const [];

    final classId = (cls['class_id'] ?? cls['id'] ?? '').toString().trim();
    final courseCode = (cls['course_code'] ?? '').toString().trim();
    final courseTitle = (cls['course_title'] ?? '').toString().trim();

    final items = <TeacherScheduleOccurrence>[];
    final baseNow = now ?? DateTime.now();
    final windowStart = baseNow.subtract(historyWindow);
    DateTime cursor = firstDateDay.isAfter(windowStart)
        ? firstDateDay
        : windowStart;
    final horizon = baseNow.add(horizonWindow);

    while (!cursor.isAfter(horizon)) {
      for (final s in pattern) {
        final dayShort = (s['day'] ?? 'Mon').toString();
        final targetWeekday = weekdayFromShort(dayShort);

        int diff = targetWeekday - cursor.weekday;
        if (diff < 0) diff += 7;
        final sessionDate = cursor.add(Duration(days: diff));

        final startTimeStr = (s['start_time'] ?? '00:00').toString();
        final parts = startTimeStr.split(':');
        final hh = parts.isNotEmpty ? int.tryParse(parts[0]) : null;
        final mm = parts.length >= 2 ? int.tryParse(parts[1]) : null;

        final startHour = (hh != null && hh >= 0 && hh <= 23) ? hh : 0;
        final startMin = (mm != null && mm >= 0 && mm <= 59) ? mm : 0;

        final start = DateTime(
          sessionDate.year,
          sessionDate.month,
          sessionDate.day,
          startHour,
          startMin,
        );
        if (start.isBefore(firstDateDay)) continue;

        final durRaw = (s['duration_min'] ?? '60').toString();
        final dur = int.tryParse(durRaw);
        final durationMin = (dur != null && dur > 0) ? dur : 60;

        items.add(
          TeacherScheduleOccurrence(
            classId: classId,
            courseCode: courseCode,
            courseTitle: courseTitle,
            start: start,
            end: start.add(Duration(minutes: durationMin)),
            isOnline: false,
            onlineBookingKey: '',
          ),
        );
      }

      cursor = cursor.add(const Duration(days: 7));
    }

    items.sort((a, b) => a.start.compareTo(b.start));
    return items;
  }

  static List<TeacherScheduleOccurrence> extractOnlineOccurrences({
    required Object? bookingData,
    required List<Map<String, dynamic>> rawClasses,
    required bool isAdminViewer,
    required String viewerUid,
    DateTime? now,
    Duration recentCutoff = const Duration(days: 2),
  }) {
    if (bookingData is! Map) return const [];

    final byCourseMeta =
        <String, ({String classId, String code, String title})>{};
    for (final c in rawClasses) {
      final cid = (c['course_id'] ?? '').toString().trim();
      if (cid.isEmpty || byCourseMeta.containsKey(cid)) continue;
      byCourseMeta[cid] = (
        classId: (c['class_id'] ?? c['id'] ?? cid).toString().trim(),
        code: (c['course_code'] ?? '').toString().trim(),
        title: (c['course_title'] ?? 'Online Class').toString().trim(),
      );
    }

    final baseNow = now ?? DateTime.now();
    final out = <TeacherScheduleOccurrence>[];
    final byCourse = Map<dynamic, dynamic>.from(bookingData);

    for (final courseEntry in byCourse.entries) {
      final courseId = courseEntry.key.toString().trim();
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

          final start = parseBookingSlotStart(dayKey, hhmm);
          if (start == null || !start.isAfter(baseNow.subtract(recentCutoff))) {
            continue;
          }

          final slotMap = Map<dynamic, dynamic>.from(slotNode);

          void maybeAdd(
            Map<dynamic, dynamic> rawSlot, {
            String fallbackTeacher = '',
          }) {
            final teacherId =
                (rawSlot['teacherId'] ??
                        rawSlot['teacherUid'] ??
                        rawSlot['teacher_id'] ??
                        fallbackTeacher)
                    .toString()
                    .trim();
            if (!isAdminViewer && teacherId != viewerUid) return;

            final learnersRaw = rawSlot['learners'];
            if (learnersRaw is! Map || learnersRaw.isEmpty) return;

            final durationRaw =
                (rawSlot['durationMinutes'] ?? rawSlot['duration_min'] ?? 60)
                    .toString();
            final parsed = int.tryParse(durationRaw);
            final duration = (parsed != null && parsed > 0) ? parsed : 60;

            final meta = byCourseMeta[courseId];
            final classId = meta?.classId ?? courseId;
            final code = meta?.code ?? '';
            final title = meta?.title ?? 'Online Class';
            final bookingKey = '$courseId|$dayKey|$hhmm|$teacherId';

            out.add(
              TeacherScheduleOccurrence(
                classId: classId,
                courseCode: code,
                courseTitle: title,
                start: start,
                end: start.add(Duration(minutes: duration)),
                isOnline: true,
                onlineBookingKey: bookingKey,
              ),
            );
          }

          final looksDirect =
              slotMap.containsKey('learners') ||
              slotMap.containsKey('teacherId') ||
              slotMap.containsKey('teacherUid') ||
              slotMap.containsKey('teacher_id');

          if (looksDirect) {
            maybeAdd(slotMap);
          } else {
            for (final teacherEntry in slotMap.entries) {
              final nested = teacherEntry.value;
              if (nested is! Map) continue;
              maybeAdd(
                Map<dynamic, dynamic>.from(nested),
                fallbackTeacher: teacherEntry.key.toString(),
              );
            }
          }
        }
      }
    }

    out.sort((a, b) => a.start.compareTo(b.start));
    return out;
  }

  static DateTime? parseBookingSlotStart(String dayKey, String hhmm) {
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

  static int weekdayFromShort(String day) {
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

  static TeacherScheduleWidgetSnapshot buildWidgetSnapshot({
    required String teacherName,
    required List<TeacherScheduleOccurrence> allOccurrences,
    DateTime? now,
    int maxItems = 3,
    bool hasSignedInTeacher = true,
  }) {
    final baseNow = now ?? DateTime.now();
    final upcoming =
        allOccurrences.where((e) => e.end.isAfter(baseNow)).toList()
          ..sort((a, b) => a.start.compareTo(b.start));

    final items = upcoming
        .take(maxItems)
        .map(
          (e) => TeacherScheduleWidgetItem(
            start: e.start,
            end: e.end,
            title: e.courseTitle.isEmpty ? 'Untitled Class' : e.courseTitle,
            isOnline: e.isOnline,
          ),
        )
        .toList();

    return TeacherScheduleWidgetSnapshot(
      teacherName: teacherName,
      updatedAt: baseNow,
      items: items,
      hasSignedInTeacher: hasSignedInTeacher,
    );
  }
}
