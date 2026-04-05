import 'package:firebase_database/firebase_database.dart';

class CourseReviewItem {
  CourseReviewItem({
    required this.id,
    required this.courseId,
    required this.uid,
    required this.firstName,
    required this.displayName,
    required this.photoUrl,
    required this.abbr,
    required this.rating,
    required this.comment,
    required this.status,
    required this.reportCount,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String courseId;
  final String uid;
  final String firstName;
  final String displayName;
  final String photoUrl;
  final String abbr;
  final int rating;
  final String comment;
  final String status;
  final int reportCount;
  final int createdAt;
  final int updatedAt;

  factory CourseReviewItem.fromMap(String id, Map<String, dynamic> map) {
    return CourseReviewItem(
      id: id,
      courseId: (map['courseId'] ?? '').toString(),
      uid: (map['uid'] ?? '').toString(),
      firstName: (map['firstName'] ?? '').toString(),
      displayName: (map['displayName'] ?? '').toString(),
      photoUrl: (map['photoUrl'] ?? '').toString(),
      abbr: (map['abbr'] ?? '').toString(),
      rating: CourseFeedbackService.asInt(map['rating']),
      comment: (map['comment'] ?? '').toString(),
      status: (map['status'] ?? 'visible').toString(),
      reportCount: CourseFeedbackService.asInt(map['reportCount']),
      createdAt: CourseFeedbackService.asInt(map['createdAt']),
      updatedAt: CourseFeedbackService.asInt(map['updatedAt']),
    );
  }
}

class LessonCommentItem {
  LessonCommentItem({
    required this.id,
    required this.courseId,
    required this.lessonId,
    required this.uid,
    required this.firstName,
    required this.displayName,
    required this.photoUrl,
    required this.abbr,
    required this.type,
    required this.text,
    required this.status,
    required this.reportCount,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String courseId;
  final String lessonId;
  final String uid;
  final String firstName;
  final String displayName;
  final String photoUrl;
  final String abbr;
  final String type;
  final String text;
  final String status;
  final int reportCount;
  final int createdAt;
  final int updatedAt;

  factory LessonCommentItem.fromMap(String id, Map<String, dynamic> map) {
    return LessonCommentItem(
      id: id,
      courseId: (map['courseId'] ?? '').toString(),
      lessonId: (map['lessonId'] ?? '').toString(),
      uid: (map['uid'] ?? '').toString(),
      firstName: (map['firstName'] ?? '').toString(),
      displayName: (map['displayName'] ?? '').toString(),
      photoUrl: (map['photoUrl'] ?? '').toString(),
      abbr: (map['abbr'] ?? '').toString(),
      type: (map['type'] ?? 'comment').toString(),
      text: (map['text'] ?? '').toString(),
      status: (map['status'] ?? 'visible').toString(),
      reportCount: CourseFeedbackService.asInt(map['reportCount']),
      createdAt: CourseFeedbackService.asInt(map['createdAt']),
      updatedAt: CourseFeedbackService.asInt(map['updatedAt']),
    );
  }
}

class CourseFeedbackService {
  static const String courseReviewsNode = 'course_reviews';
  static const String courseReviewStatsNode = 'course_review_stats';
  static const String reviewReportsNode = 'review_reports';
  static const String lessonCommentsNode = 'lesson_comments';
  static const String lessonRepliesNode = 'lesson_comment_replies';
  static const String commentReportsNode = 'comment_reports';

  static final DatabaseReference _db = FirebaseDatabase.instance.ref();

  static int asInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  static String _safe(dynamic v) => (v ?? '').toString().trim();

  static String firstNameFromDisplayName(String fullName) {
    final trimmed = fullName.trim();
    if (trimmed.isEmpty) return 'Learner';
    return trimmed.split(RegExp(r'\s+')).first;
  }

  static String abbreviationFromName(String fullName) {
    final parts = fullName
        .trim()
        .split(RegExp(r'\s+'))
        .where((e) => e.trim().isNotEmpty)
        .toList();
    if (parts.isEmpty) return 'U';
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
  }

  static Future<Map<String, String>> loadUserIdentity(String uid) async {
    final out = <String, String>{
      'displayName': 'Learner',
      'firstName': 'Learner',
      'abbr': 'L',
      'photoUrl': '',
    };

    final snap = await _db.child('users').child(uid).get();
    if (!snap.exists || snap.value is! Map) return out;

    final m = Map<String, dynamic>.from(snap.value as Map);
    final first = _safe(m['first_name']);
    final last = _safe(m['last_name']);
    final display = ('$first $last').trim();
    final finalName = display.isEmpty ? 'Learner' : display;

    final photo = _safe(m['profile_photo']);
    out['displayName'] = finalName;
    out['firstName'] = firstNameFromDisplayName(finalName);
    out['abbr'] = abbreviationFromName(finalName);
    out['photoUrl'] = photo;
    return out;
  }

  static Future<bool> isUserEnrolledInCourse(
    String uid,
    String courseId,
  ) async {
    final snap = await _db.child('users').child(uid).child('courses').get();
    if (!snap.exists || snap.value is! Map) return false;
    final raw = Map<dynamic, dynamic>.from(snap.value as Map);
    for (final entry in raw.entries) {
      final value = entry.value;
      if (value is! Map) continue;
      final m = value.map((k, v) => MapEntry(k.toString(), v));
      final fromClass = _safe((m['class'] as Map?)?['course_id']);
      final fromRoot = _safe(m['id']);
      if (entry.key.toString() == courseId ||
          fromClass == courseId ||
          fromRoot == courseId) {
        return true;
      }
    }
    return false;
  }

  static Future<void> upsertCourseReview({
    required String courseId,
    required String uid,
    required int rating,
    required String comment,
  }) async {
    final identity = await loadUserIdentity(uid);
    final now = DateTime.now().millisecondsSinceEpoch;
    final ref = _db.child(courseReviewsNode).child(courseId).child(uid);
    final existing = await ref.get();
    final createdAt = existing.exists && existing.value is Map
        ? asInt((existing.value as Map)['createdAt'])
        : now;

    await ref.set({
      'uid': uid,
      'courseId': courseId,
      'firstName': identity['firstName'] ?? 'Learner',
      'displayName': identity['displayName'] ?? 'Learner',
      'photoUrl': identity['photoUrl'] ?? '',
      'abbr': identity['abbr'] ?? 'L',
      'rating': rating,
      'comment': comment.trim(),
      'status': 'visible',
      'reportCount': asInt((existing.value as Map?)?['reportCount']),
      'createdAt': createdAt,
      'updatedAt': now,
    });

    await recomputeCourseReviewStats(courseId);
  }

  static Future<List<CourseReviewItem>> listCourseReviews(
    String courseId, {
    bool visibleOnly = true,
  }) async {
    final snap = await _db.child(courseReviewsNode).child(courseId).get();
    if (!snap.exists || snap.value is! Map) return const [];
    final raw = Map<dynamic, dynamic>.from(snap.value as Map);
    final out = <CourseReviewItem>[];
    raw.forEach((key, value) {
      if (value is! Map) return;
      final map = value.map((k, v) => MapEntry(k.toString(), v));
      final item = CourseReviewItem.fromMap(key.toString(), map);
      if (visibleOnly && item.status != 'visible') return;
      out.add(item);
    });
    return out;
  }

  static Future<void> reportCourseReview({
    required String courseId,
    required String reviewId,
    required String uid,
    required String reason,
  }) async {
    final reportRef = _db
        .child(reviewReportsNode)
        .child(courseId)
        .child(reviewId)
        .push();
    await reportRef.set({
      'uid': uid,
      'reason': reason.trim().isEmpty ? 'Inappropriate content' : reason.trim(),
      'createdAt': DateTime.now().millisecondsSinceEpoch,
    });

    final reviewRef = _db
        .child(courseReviewsNode)
        .child(courseId)
        .child(reviewId);
    final snap = await reviewRef.get();
    if (snap.exists && snap.value is Map) {
      final cur = Map<String, dynamic>.from(snap.value as Map);
      await reviewRef.update({'reportCount': asInt(cur['reportCount']) + 1});
    }
  }

  static Future<void> moderateCourseReview({
    required String courseId,
    required String reviewId,
    required String status,
  }) async {
    await _db.child(courseReviewsNode).child(courseId).child(reviewId).update({
      'status': status,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    });
    await recomputeCourseReviewStats(courseId);
  }

  static Future<void> recomputeCourseReviewStats(String courseId) async {
    final reviews = await listCourseReviews(courseId, visibleOnly: true);
    var total = 0;
    final stars = <String, int>{'1': 0, '2': 0, '3': 0, '4': 0, '5': 0};
    for (final r in reviews) {
      total += r.rating;
      final key = r.rating.clamp(1, 5).toString();
      stars[key] = (stars[key] ?? 0) + 1;
    }
    final count = reviews.length;
    final avg = count == 0 ? 0.0 : (total / count);
    await _db.child(courseReviewStatsNode).child(courseId).set({
      'courseId': courseId,
      'visibleCount': count,
      'averageRating': avg,
      'stars': stars,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    });
  }

  static Future<void> addLessonComment({
    required String courseId,
    required String lessonId,
    required String uid,
    required String text,
    String type = 'comment',
  }) async {
    final identity = await loadUserIdentity(uid);
    final now = DateTime.now().millisecondsSinceEpoch;
    final ref = _db
        .child(lessonCommentsNode)
        .child(courseId)
        .child(lessonId)
        .push();
    await ref.set({
      'uid': uid,
      'courseId': courseId,
      'lessonId': lessonId,
      'firstName': identity['firstName'] ?? 'Learner',
      'displayName': identity['displayName'] ?? 'Learner',
      'photoUrl': identity['photoUrl'] ?? '',
      'abbr': identity['abbr'] ?? 'L',
      'type': type,
      'text': text.trim(),
      'status': 'visible',
      'reportCount': 0,
      'createdAt': now,
      'updatedAt': now,
    });
  }

  static Future<void> addLessonReply({
    required String courseId,
    required String lessonId,
    required String commentId,
    required String uid,
    required String text,
  }) async {
    final identity = await loadUserIdentity(uid);
    final now = DateTime.now().millisecondsSinceEpoch;
    final ref = _db
        .child(lessonRepliesNode)
        .child(courseId)
        .child(lessonId)
        .child(commentId)
        .push();
    await ref.set({
      'uid': uid,
      'firstName': identity['firstName'] ?? 'Learner',
      'displayName': identity['displayName'] ?? 'Learner',
      'photoUrl': identity['photoUrl'] ?? '',
      'abbr': identity['abbr'] ?? 'L',
      'text': text.trim(),
      'status': 'visible',
      'createdAt': now,
      'updatedAt': now,
    });
  }

  static Future<List<LessonCommentItem>> listLessonComments(
    String courseId,
    String lessonId, {
    bool visibleOnly = true,
  }) async {
    final snap = await _db
        .child(lessonCommentsNode)
        .child(courseId)
        .child(lessonId)
        .get();
    if (!snap.exists || snap.value is! Map) return const [];
    final raw = Map<dynamic, dynamic>.from(snap.value as Map);
    final out = <LessonCommentItem>[];
    raw.forEach((key, value) {
      if (value is! Map) return;
      final map = value.map((k, v) => MapEntry(k.toString(), v));
      final item = LessonCommentItem.fromMap(key.toString(), map);
      if (visibleOnly && item.status != 'visible') return;
      out.add(item);
    });
    return out;
  }

  static Future<List<Map<String, dynamic>>> listLessonReplies(
    String courseId,
    String lessonId,
    String commentId,
  ) async {
    final snap = await _db
        .child(lessonRepliesNode)
        .child(courseId)
        .child(lessonId)
        .child(commentId)
        .get();
    if (!snap.exists || snap.value is! Map) return const [];
    final raw = Map<dynamic, dynamic>.from(snap.value as Map);
    final out = <Map<String, dynamic>>[];
    raw.forEach((key, value) {
      if (value is! Map) return;
      final map = value.map((k, v) => MapEntry(k.toString(), v));
      out.add({'id': key.toString(), ...map});
    });
    out.sort((a, b) => asInt(a['createdAt']).compareTo(asInt(b['createdAt'])));
    return out;
  }

  static Future<void> reportLessonComment({
    required String courseId,
    required String lessonId,
    required String commentId,
    required String uid,
    required String reason,
  }) async {
    final reportRef = _db
        .child(commentReportsNode)
        .child(courseId)
        .child(lessonId)
        .child(commentId)
        .push();
    await reportRef.set({
      'uid': uid,
      'reason': reason.trim().isEmpty ? 'Inappropriate content' : reason.trim(),
      'createdAt': DateTime.now().millisecondsSinceEpoch,
    });

    final commentRef = _db
        .child(lessonCommentsNode)
        .child(courseId)
        .child(lessonId)
        .child(commentId);
    final snap = await commentRef.get();
    if (snap.exists && snap.value is Map) {
      final cur = Map<String, dynamic>.from(snap.value as Map);
      await commentRef.update({'reportCount': asInt(cur['reportCount']) + 1});
    }
  }

  static Future<void> moderateLessonComment({
    required String courseId,
    required String lessonId,
    required String commentId,
    required String status,
  }) async {
    await _db
        .child(lessonCommentsNode)
        .child(courseId)
        .child(lessonId)
        .child(commentId)
        .update({
          'status': status,
          'updatedAt': DateTime.now().millisecondsSinceEpoch,
        });
  }
}
