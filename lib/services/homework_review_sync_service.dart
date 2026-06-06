import 'package:firebase_database/firebase_database.dart';

class HomeworkReviewSyncService {
  static int toInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  static String normalizeStatus(dynamic raw) {
    final s = (raw ?? '').toString().trim().toLowerCase();
    if (s == 'approved') return 'pass';
    if (s == 'needs_work') return 'redo';
    return s;
  }

  static bool isHomeworkReviewed(Map<String, dynamic> hw) {
    final reviewedAt = toInt(hw['reviewedAt']);
    final reviewStatus = normalizeStatus(hw['reviewStatus']);
    return reviewedAt > 0 || reviewStatus.isNotEmpty;
  }

  static HomeworkReviewPatch? parseEvaluationText(
    String raw, {
    int fallbackReviewedAt = 0,
  }) {
    final text = raw.trim();
    if (text.isEmpty) return null;

    final lower = text.toLowerCase();
    final isHomeworkEval =
        lower.contains('homework: pass') ||
        lower.contains('homework: redo') ||
        lower.startsWith('✅ pass') ||
        lower.startsWith('🔁 redo');
    if (!isHomeworkEval) return null;

    final isRedo = lower.contains('redo');
    final scoreMatch = RegExp(
      r'score:\s*(\d{1,3})\s*/\s*100',
      caseSensitive: false,
    ).firstMatch(text);
    final compactScoreMatch = RegExp(r'(\d{1,3})\s*/\s*100').firstMatch(text);
    final scoreRaw = scoreMatch?.group(1) ?? compactScoreMatch?.group(1);
    final score = (int.tryParse(scoreRaw ?? '') ?? 0).clamp(0, 100);

    final gradeMatch = RegExp(
      r'grade:\s*([A-Za-z][+-]?)',
      caseSensitive: false,
    ).firstMatch(text);
    final commentMatch = RegExp(
      r'comment:\s*([\s\S]+)',
      caseSensitive: false,
    ).firstMatch(text);

    return HomeworkReviewPatch(
      reviewedAt: fallbackReviewedAt > 0
          ? fallbackReviewedAt
          : DateTime.now().millisecondsSinceEpoch,
      reviewStatus: isRedo ? 'redo' : 'pass',
      reviewScore: score,
      reviewGrade: (gradeMatch?.group(1) ?? '').trim(),
      reviewNote: (commentMatch?.group(1) ?? '').trim(),
      needsRedo: isRedo,
    );
  }

  static Future<HomeworkReviewPatch?> latestEvaluationForThread(
    FirebaseDatabase db,
    String threadId, {
    String lastMessage = '',
    int updatedAt = 0,
  }) async {
    final tid = threadId.trim();
    if (tid.isEmpty) return null;

    try {
      final snap = await db
          .ref('mail_messages/$tid')
          .orderByChild('createdAt')
          .limitToLast(40)
          .get();
      if (snap.exists && snap.value is Map) {
        final rows = <Map<String, dynamic>>[];
        final raw = (snap.value as Map).map((k, v) => MapEntry('$k', v));
        for (final entry in raw.entries) {
          if (entry.value is! Map) continue;
          final row = (entry.value as Map).map((k, v) => MapEntry('$k', v));
          rows.add(row);
        }
        rows.sort(
          (a, b) => toInt(b['createdAt']).compareTo(toInt(a['createdAt'])),
        );
        for (final row in rows) {
          final type = (row['type'] ?? '').toString().trim().toLowerCase();
          final body = (row['body'] ?? '').toString();
          if (type != 'homework_eval' && parseEvaluationText(body) == null) {
            continue;
          }
          final parsed = parseEvaluationText(
            body,
            fallbackReviewedAt: toInt(row['createdAt']),
          );
          if (parsed != null) return parsed;
        }
      }
    } catch (_) {}

    return parseEvaluationText(lastMessage, fallbackReviewedAt: updatedAt);
  }

  static Future<HomeworkReviewPatch?> repairHomeworkNodeFromThread({
    required FirebaseDatabase db,
    required String threadId,
    required String homeworkRefPath,
    required String lastMessage,
    required int updatedAt,
  }) async {
    final hwRef = homeworkRefPath.trim();
    if (hwRef.isEmpty) return null;

    final patch = await latestEvaluationForThread(
      db,
      threadId,
      lastMessage: lastMessage,
      updatedAt: updatedAt,
    );
    if (patch == null) return null;

    try {
      final snap = await db.ref(hwRef).get();
      final hw = snap.value is Map
          ? (snap.value as Map).map((k, v) => MapEntry('$k', v))
          : <String, dynamic>{};
      if (isHomeworkReviewed(hw)) return patch;
      await db.ref(hwRef).update(patch.toMap());
    } catch (_) {}

    return patch;
  }

  static Future<HomeworkReviewBackfillResult> runBulkReviewBackfill({
    required FirebaseDatabase db,
  }) async {
    final snap = await db.ref('mail_threads').get();
    if (!snap.exists || snap.value is! Map) {
      return const HomeworkReviewBackfillResult(
        checkedThreads: 0,
        homeworkThreads: 0,
        repaired: 0,
        skippedReviewed: 0,
        missingHomeworkRef: 0,
        missingHomeworkNode: 0,
        noEvaluationFound: 0,
        failed: 0,
      );
    }

    final raw = (snap.value as Map).map((k, v) => MapEntry('$k', v));
    final entries = raw.entries.toList(growable: false);

    var checkedThreads = 0;
    var homeworkThreads = 0;
    var repaired = 0;
    var skippedReviewed = 0;
    var missingHomeworkRef = 0;
    var missingHomeworkNode = 0;
    var noEvaluationFound = 0;
    var failed = 0;

    for (final entry in entries) {
      checkedThreads++;
      final threadId = entry.key.trim();
      if (threadId.isEmpty || entry.value is! Map) continue;

      final t = (entry.value as Map).map((k, v) => MapEntry('$k', v));
      final type = (t['type'] ?? '').toString().trim().toLowerCase();
      var hwRefPath = (t['homeworkRef'] ?? '').toString().trim();
      final subject = (t['subject'] ?? '').toString().trim().toLowerCase();

      final looksHomework =
          type == 'homework' ||
          hwRefPath.isNotEmpty ||
          subject.startsWith('[hw]');
      if (!looksHomework) continue;
      homeworkThreads++;

      if (hwRefPath.isEmpty) {
        final learnerUid = (t['learnerUid'] ?? '').toString().trim();
        final courseKey = (t['courseKey'] ?? '').toString().trim();
        final sessionId = (t['sessionId'] ?? '').toString().trim();
        if (learnerUid.isNotEmpty &&
            courseKey.isNotEmpty &&
            sessionId.isNotEmpty) {
          hwRefPath =
              'users/$learnerUid/courses/$courseKey/attendance/$sessionId/homework';
        }
      }

      if (hwRefPath.isEmpty) {
        missingHomeworkRef++;
        continue;
      }

      try {
        final hwSnap = await db.ref(hwRefPath).get();
        if (!hwSnap.exists || hwSnap.value is! Map) {
          missingHomeworkNode++;
          continue;
        }

        final hw = (hwSnap.value as Map).map((k, v) => MapEntry('$k', v));
        if (isHomeworkReviewed(hw)) {
          skippedReviewed++;
          continue;
        }

        final patch = await latestEvaluationForThread(
          db,
          threadId,
          lastMessage: (t['lastMessage'] ?? '').toString(),
          updatedAt: toInt(t['updatedAt']),
        );

        if (patch == null) {
          noEvaluationFound++;
          continue;
        }

        await db.ref(hwRefPath).update(patch.toMap());
        repaired++;
      } catch (_) {
        failed++;
      }
    }

    return HomeworkReviewBackfillResult(
      checkedThreads: checkedThreads,
      homeworkThreads: homeworkThreads,
      repaired: repaired,
      skippedReviewed: skippedReviewed,
      missingHomeworkRef: missingHomeworkRef,
      missingHomeworkNode: missingHomeworkNode,
      noEvaluationFound: noEvaluationFound,
      failed: failed,
    );
  }
}

class HomeworkReviewBackfillResult {
  const HomeworkReviewBackfillResult({
    required this.checkedThreads,
    required this.homeworkThreads,
    required this.repaired,
    required this.skippedReviewed,
    required this.missingHomeworkRef,
    required this.missingHomeworkNode,
    required this.noEvaluationFound,
    required this.failed,
  });

  final int checkedThreads;
  final int homeworkThreads;
  final int repaired;
  final int skippedReviewed;
  final int missingHomeworkRef;
  final int missingHomeworkNode;
  final int noEvaluationFound;
  final int failed;

  Map<String, dynamic> toMap() {
    return {
      'checkedThreads': checkedThreads,
      'homeworkThreads': homeworkThreads,
      'repaired': repaired,
      'skippedReviewed': skippedReviewed,
      'missingHomeworkRef': missingHomeworkRef,
      'missingHomeworkNode': missingHomeworkNode,
      'noEvaluationFound': noEvaluationFound,
      'failed': failed,
    };
  }
}

class HomeworkReviewPatch {
  const HomeworkReviewPatch({
    required this.reviewedAt,
    required this.reviewStatus,
    required this.reviewScore,
    required this.reviewGrade,
    required this.reviewNote,
    required this.needsRedo,
  });

  final int reviewedAt;
  final String reviewStatus;
  final int reviewScore;
  final String reviewGrade;
  final String reviewNote;
  final bool needsRedo;

  Map<String, dynamic> toMap() {
    return {
      'reviewedAt': reviewedAt,
      'reviewStatus': reviewStatus,
      'reviewScore': reviewScore,
      'reviewGrade': reviewGrade,
      'reviewNote': reviewNote,
      'needsRedo': needsRedo,
    };
  }
}
