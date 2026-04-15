import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

import 'payment_dialog_shared.dart';

class AdminPaymentSummarySyncService {
  static bool _running = false;

  static Future<void> runForAdminLogin({int batchSize = 6}) async {
    if (_running) return;

    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;

    final adminUid = currentUser.uid.trim();
    if (adminUid.isEmpty) return;

    final db = FirebaseDatabase.instance;
    final rootRef = db.ref();

    _running = true;
    try {
      final adminSnap = await rootRef.child('admins/$adminUid').get();
      if (adminSnap.value != true) return;

      final usersSnap = await rootRef.child('users').get();
      final usersVal = usersSnap.value;
      if (usersVal is! Map) return;

      final targets = <_SyncTarget>[];

      usersVal.forEach((uidRaw, userRaw) {
        if (uidRaw == null || userRaw == null || userRaw is! Map) return;
        final uid = uidRaw.toString().trim();
        if (uid.isEmpty) return;

        final userMap = userRaw.map((k, v) => MapEntry(k.toString(), v));
        final role = (userMap['role'] ?? '').toString().trim().toLowerCase();
        final isLearner =
            role == 'learner' || role == 'learners' || role == 'learner(s)';
        if (!isLearner) return;

        final coursesVal = userMap['courses'];
        if (coursesVal is! Map) return;

        coursesVal.forEach((courseKeyRaw, courseRaw) {
          if (courseKeyRaw == null || courseRaw == null || courseRaw is! Map) {
            return;
          }

          final courseKey = courseKeyRaw.toString().trim();
          if (courseKey.isEmpty || !courseKey.startsWith('course_')) return;

          targets.add(_SyncTarget(uid: uid, courseKey: courseKey));
        });
      });

      if (targets.isEmpty) return;

      final safeBatchSize = batchSize <= 0 ? 1 : batchSize;
      for (var i = 0; i < targets.length; i += safeBatchSize) {
        final chunk = targets.skip(i).take(safeBatchSize);
        await Future.wait(
          chunk.map((target) async {
            try {
              await PaymentDialogShared.repairLearnerCourseSummary(
                db: db,
                uid: target.uid,
                courseKey: target.courseKey,
              );
            } catch (_) {
              // Keep sync resilient: skip failed learner-course and continue.
            }
          }),
        );
      }
    } finally {
      _running = false;
    }
  }
}

class _SyncTarget {
  const _SyncTarget({required this.uid, required this.courseKey});

  final String uid;
  final String courseKey;
}
