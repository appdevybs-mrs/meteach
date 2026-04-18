import 'package:firebase_database/firebase_database.dart';

class ReminderConsistencyService {
  ReminderConsistencyService._();

  static String normalizeRole(dynamic raw) {
    final s = (raw ?? '').toString().trim().toLowerCase();
    if (s == 'teacher' ||
        s == 'teachers' ||
        s == 'teacher(s)' ||
        s == 'teach' ||
        s == 'instructor' ||
        s == 'prof') {
      return 'teacher';
    }
    if (s == 'staff' || s == 'employee') return 'staff';
    if (s == 'admin' ||
        s == 'adin' ||
        s == 'admn' ||
        s == 'adm' ||
        s == 'administration' ||
        s == 'administrator') {
      return 'admin';
    }
    if (s == 'learner' ||
        s == 'learners' ||
        s == 'learner(s)' ||
        s == 'lerner' ||
        s == 'student' ||
        s == 'pupil') {
      return 'learner';
    }
    return 'unknown';
  }

  static String normalizeStatus(dynamic raw) {
    final s = (raw ?? '').toString().trim().toLowerCase();
    if (s == 'done') return 'done';
    if (s == 'read' || s == 'seen') return 'read';
    if (s == 'new' || s == 'queued' || s == 'push_sent' || s == 'push_error') {
      return 'new';
    }
    return 'new';
  }

  static Map<String, dynamic> buildReminderPayload({
    required String targetUid,
    required String targetRole,
    required String senderUid,
    required String senderRole,
    required String title,
    required String description,
    required String kind,
    required int? dueAtMs,
    required String attachmentUrl,
    required String attachmentName,
    required Map<String, dynamic> legacyTarget,
  }) {
    return {
      'kind': kind,
      'title': title,
      'description': description,
      'dueAt': dueAtMs,
      'attachment_url': attachmentUrl,
      'attachment_name': attachmentName,
      'createdAt': ServerValue.timestamp,
      'createdByUid': senderUid,
      'target': {'uid': targetUid, 'role': normalizeRole(targetRole)},
      'sender': {'uid': senderUid, 'role': normalizeRole(senderRole)},
      'status': 'new',
      'readAt': null,
      'doneAt': null,
      'teacher': legacyTarget,
      'push': {
        'status': 'pending',
        'attemptedAt': null,
        'sentAt': null,
        'error': null,
      },
    };
  }

  static Future<void> verifyReminderOnce({
    required DatabaseReference reminderRef,
    required String targetUid,
    required String targetRole,
    required String senderUid,
    required String senderRole,
  }) async {
    Map<String, dynamic> patch = <String, dynamic>{};
    try {
      final snap = await reminderRef.get();
      final m = snap.value is Map
          ? (snap.value as Map).map((k, v) => MapEntry(k.toString(), v))
          : <String, dynamic>{};

      final target = m['target'] is Map
          ? (m['target'] as Map).map((k, v) => MapEntry(k.toString(), v))
          : <String, dynamic>{};
      final sender = m['sender'] is Map
          ? (m['sender'] as Map).map((k, v) => MapEntry(k.toString(), v))
          : <String, dynamic>{};

      if ((target['uid'] ?? '').toString().trim().isEmpty) {
        patch['target/uid'] = targetUid;
      }
      if (normalizeRole(target['role']) == 'unknown') {
        patch['target/role'] = normalizeRole(targetRole);
      }
      if ((sender['uid'] ?? '').toString().trim().isEmpty) {
        patch['sender/uid'] = senderUid;
      }
      if (normalizeRole(sender['role']) == 'unknown') {
        patch['sender/role'] = normalizeRole(senderRole);
      }

      final normalizedStatus = normalizeStatus(m['status']);
      if ((m['status'] ?? '').toString().trim().toLowerCase() !=
          normalizedStatus) {
        patch['status'] = normalizedStatus;
      }

      if (patch.isNotEmpty) {
        await reminderRef.update(patch);
      }
    } catch (_) {
      if (patch.isNotEmpty) {
        try {
          await reminderRef.update(patch);
        } catch (_) {}
      }
    }
  }
}
