import 'package:firebase_database/firebase_database.dart';

import '../teacher/teacher_schedule_data_service.dart';
import 'teacher_schedule_widget_service.dart';

class TeacherScheduleWidgetSyncService {
  TeacherScheduleWidgetSyncService._();

  static final TeacherScheduleWidgetSyncService instance =
      TeacherScheduleWidgetSyncService._();

  final FirebaseDatabase _db = FirebaseDatabase.instance;

  Future<void> syncForTeacher(String uid) async {
    if (uid.trim().isEmpty) {
      await TeacherScheduleWidgetService.instance.clearSnapshot();
      return;
    }

    try {
      final identity = await TeacherScheduleDataService.loadViewerIdentity(uid);
      final classesSnap = await _db.ref('classes').get();

      final rawClasses = <Map<String, dynamic>>[];
      final allOccurrences = <TeacherScheduleOccurrence>[];
      final now = DateTime.now();

      if (classesSnap.exists && classesSnap.value is Map) {
        final classes = Map<dynamic, dynamic>.from(classesSnap.value as Map);
        for (final entry in classes.entries) {
          final value = entry.value;
          if (value is! Map) continue;

          final cls = Map<String, dynamic>.from(value);
          if (!TeacherScheduleDataService.matchesTeacherClass(
            cls,
            teacherUid: uid,
            teacherName: identity.name,
            teacherSerial: identity.serial,
          )) {
            continue;
          }

          rawClasses.add(cls);
          allOccurrences.addAll(
            TeacherScheduleDataService.generateOccurrences(
              cls,
            ).where((occ) => occ.end.isAfter(now)),
          );
        }
      }

      final bookingsSnap = await _db.ref('booking_reservations').get();
      if (bookingsSnap.exists && bookingsSnap.value != null) {
        allOccurrences.addAll(
          TeacherScheduleDataService.extractOnlineOccurrences(
            bookingData: bookingsSnap.value,
            rawClasses: rawClasses,
            isAdminViewer: false,
            viewerUid: uid,
            recentCutoff: const Duration(days: 0),
          ).where((occ) => occ.end.isAfter(now)),
        );
      }

      allOccurrences.sort((a, b) => a.start.compareTo(b.start));
      final snapshot = TeacherScheduleDataService.buildWidgetSnapshot(
        teacherName: identity.name,
        allOccurrences: allOccurrences,
      );
      await TeacherScheduleWidgetService.instance.publishSnapshot(snapshot);
    } catch (_) {
      // Avoid breaking auth/navigation if widget sync fails.
    }
  }
}
