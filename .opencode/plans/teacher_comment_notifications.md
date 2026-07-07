# Plan: Add teacher comment notifications + learner approval notification

## Files to change
Only one file: `lib/services/course_feedback_service.dart`

## Fix 1 — Teacher not notified when learner comments (lines 164-203)

**Root cause**: `_assignedTeacherUidsForCourse()` only scans `classes` node. Teachers assigned via `courses/{id}/instructors_map`, `courses/{id}/instructors`, or `payments` are never found.

**Change**: Expand the method to also check:
- `courses/{courseId}` for `instructors_map` (Map<uid, info>) and `instructors` (List/Map of objects with `uid`)
- `payments` node for entries with matching `courseId` + `teacherId`/`teacherUid`

Keep the existing `classes` scan as-is. Add the two new lookups after it, all inside the existing try-catch.

### Full replacement for `_assignedTeacherUidsForCourse`:

```dart
static Future<Set<String>> _assignedTeacherUidsForCourse(
    String courseId,
  ) async {
    final safeCourseId = courseId.trim();
    if (safeCourseId.isEmpty) return <String>{};

    final out = <String>{};
    try {
      // 1. Check classes node (existing logic)
      final classesSnap = await _db.child('classes').get();
      if (classesSnap.exists && classesSnap.value is Map) {
        final raw = Map<dynamic, dynamic>.from(classesSnap.value as Map);
        for (final entry in raw.entries) {
          final val = entry.value;
          if (val is! Map) continue;

          final cls = val.map((k, v) => MapEntry(k.toString(), v));
          final classCourseId = _safe(cls['course_id']);
          if (classCourseId != safeCourseId) continue;

          final directTeacher = _safe(
            cls['teacherUid'] ??
                cls['teacher_uid'] ??
                cls['teacherId'] ??
                cls['teacher_id'] ??
                cls['instructorUid'],
          );
          if (directTeacher.isNotEmpty) out.add(directTeacher);

          final currentInstructor = cls['instructor_current'];
          if (currentInstructor is Map) {
            final m = currentInstructor
                .map((k, v) => MapEntry(k.toString(), v));
            final uid = _safe(m['uid']);
            if (uid.isNotEmpty) out.add(uid);
          }
        }
      }

      // 2. Check courses/{courseId}/instructors_map and instructors
      final courseSnap = await _db.child('courses').child(safeCourseId).get();
      if (courseSnap.exists && courseSnap.value is Map) {
        final courseData =
            Map<String, dynamic>.from(courseSnap.value as Map);

        final instructorsMap = courseData['instructors_map'];
        if (instructorsMap is Map) {
          for (final uid in instructorsMap.keys) {
            final clean = uid.toString().trim();
            if (clean.isNotEmpty) out.add(clean);
          }
        }

        final instructors = courseData['instructors'];
        if (instructors is List) {
          for (final item in instructors) {
            if (item is Map) {
              final uid = _safe((item as Map)['uid']);
              if (uid.isNotEmpty) out.add(uid);
            }
          }
        } else if (instructors is Map) {
          for (final entry in (instructors as Map).entries) {
            final uid = entry.value is Map
                ? _safe((entry.value as Map)['uid'])
                : entry.key.toString().trim();
            if (uid.isNotEmpty) out.add(uid);
          }
        }
      }

      // 3. Check payments with matching courseId + teacherId
      final paymentsSnap = await _db.child('payments').get();
      if (paymentsSnap.exists && paymentsSnap.value is Map) {
        for (final entry
            in (paymentsSnap.value as Map).entries) {
          if (entry.value is! Map) continue;
          final p = (entry.value as Map)
              .map((k, v) => MapEntry(k.toString(), v));
          final pCourseId =
              (p['courseId'] ??
                      p['course_id'] ??
                      p['courseKey'] ??
                      p['course_key'] ??
                      '')
                  .toString()
                  .trim();
          if (pCourseId != safeCourseId) continue;
          final teacherUid =
              (p['teacherId'] ??
                      p['teacher_id'] ??
                      p['teacherUid'] ??
                      p['teacher_uid'] ??
                      '')
                  .toString()
                  .trim();
          if (teacherUid.isNotEmpty) out.add(teacherUid);
        }
      }
    } catch (_) {}

    return out;
  }
```

## Fix 2 — Learner not notified when teacher approves comment

### 2a. Add new method `_notifyCommentApprovedToLearner` (add after `_notifyRecordedCommentImmediately`)

Insert after line 283 (end of `_notifyRecordedCommentImmediately`):

```dart
  static Future<void> _notifyCommentApprovedToLearner({
    required String courseId,
    required String lessonId,
    required String commentId,
    required String learnerUid,
  }) async {
    final safeCourseId = _sanitizeEventPart(courseId);
    final safeLessonId = _sanitizeEventPart(lessonId);
    final safeCommentId = _sanitizeEventPart(commentId);
    final safeLearnerUid = learnerUid.trim();
    if (safeCourseId.isEmpty ||
        safeLessonId.isEmpty ||
        safeCommentId.isEmpty ||
        safeLearnerUid.isEmpty) {
      return;
    }

    const title = 'Reflection Approved';
    final body =
        'Your learning reflection has been reviewed and approved by your teacher.';

    try {
      await PushDispatchService.dispatchToUser(
        intent: PushIntent.recordedComment,
        targetUid: safeLearnerUid,
        title: title,
        message: body,
        context: const PushDispatchContext(
          screen: 'services/course_feedback_service',
          action: 'comment_approved_to_learner',
        ),
        eventParts: [
          'comment_approved_${safeCourseId}_${safeLessonId}_${safeCommentId}_$safeLearnerUid',
        ],
        route: 'recorded_comment',
        data: <String, dynamic>{
          'courseId': courseId,
          'lessonId': lessonId,
          'commentId': commentId,
          'learnerUid': safeLearnerUid,
        },
      );
    } catch (_) {}
  }
```

### 2b. Modify `moderateLessonComment()` (line 862-877)

Replace the current method to read learner UID before updating and call the new notification:

```dart
  static Future<void> moderateLessonComment({
    required String courseId,
    required String lessonId,
    required String commentId,
    required String status,
  }) async {
    String? learnerUid;
    if (status == statusVisible) {
      try {
        final uidSnap = await _db
            .child(lessonCommentsNode)
            .child(courseId)
            .child(lessonId)
            .child(commentId)
            .child('uid')
            .get();
        if (uidSnap.exists) {
          learnerUid = (uidSnap.value ?? '').toString().trim();
        }
      } catch (_) {}
    }

    await _db
        .child(lessonCommentsNode)
        .child(courseId)
        .child(lessonId)
        .child(commentId)
        .update({
          'status': status,
          'updatedAt': DateTime.now().millisecondsSinceEpoch,
        });

    if (status == statusVisible &&
        learnerUid != null &&
        learnerUid.isNotEmpty) {
      try {
        await _notifyCommentApprovedToLearner(
          courseId: courseId,
          lessonId: lessonId,
          commentId: commentId,
          learnerUid: learnerUid,
        );
      } catch (_) {}
    }
  }
```

## Summary of Changes

| Change | Location | Lines |
|--------|----------|-------|
| Expand teacher lookup to include `instructors_map`, `instructors`, `payments` | `_assignedTeacherUidsForCourse()` | 164-203 → replacement |
| Add learner approval notification method | New method after `_notifyRecordedCommentImmediately` | After line 283 |
| Modify `moderateLessonComment()` to call learner notification | Line 862-877 → replacement |

No screen files or other services need changes.
