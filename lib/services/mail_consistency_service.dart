import 'package:firebase_database/firebase_database.dart';

class MailConsistencyService {
  MailConsistencyService._();

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

  static int toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  static bool isStaffOrTeacherRole(String role) {
    final normalized = normalizeRole(role);
    return normalized == 'teacher' ||
        normalized == 'staff' ||
        normalized == 'admin';
  }

  static Future<String> resolveUserRole(
    FirebaseDatabase db,
    String uid, {
    String seedRole = '',
  }) async {
    final normalizedSeed = normalizeRole(seedRole);
    if (normalizedSeed != 'unknown') return normalizedSeed;
    if (uid.trim().isEmpty) return 'unknown';
    try {
      final snap = await db.ref('users/$uid/role').get();
      return normalizeRole(snap.value);
    } catch (_) {
      return 'unknown';
    }
  }

  static Future<Map<String, String>> fetchUserLabel(
    FirebaseDatabase db,
    String uid,
  ) async {
    if (uid.trim().isEmpty) {
      return const {'name': 'User', 'role': 'unknown'};
    }
    try {
      final snap = await db.ref('users/$uid').get();
      final v = snap.value;
      if (v is! Map) return const {'name': 'User', 'role': 'unknown'};
      final m = v.map((k, vv) => MapEntry(k.toString(), vv));
      final first = (m['first_name'] ?? m['firstName'] ?? '').toString().trim();
      final last = (m['last_name'] ?? m['lastName'] ?? '').toString().trim();
      final full = ('$first $last').trim();
      final email = (m['email'] ?? '').toString().trim();
      final role = normalizeRole(m['role']);
      return {
        'name': full.isEmpty ? (email.isEmpty ? 'User' : email) : full,
        'role': role,
      };
    } catch (_) {
      return const {'name': 'User', 'role': 'unknown'};
    }
  }

  static Future<int> runAdminInboxIntegritySweep({
    required FirebaseDatabase db,
    required String adminUid,
  }) async {
    final uid = adminUid.trim();
    if (uid.isEmpty) return 0;

    final updates = <String, dynamic>{};
    int touched = 0;

    final indexSnap = await db.ref('mail_index/$uid').get();
    final indexRoot = indexSnap.value is Map
        ? (indexSnap.value as Map).map((k, v) => MapEntry(k.toString(), v))
        : <String, dynamic>{};

    final threadsSnap = await db
        .ref('mail_threads')
        .orderByChild('participants/$uid')
        .equalTo(true)
        .get();

    if (!threadsSnap.exists || threadsSnap.value is! Map) return 0;

    final threads = (threadsSnap.value as Map).map(
      (k, v) => MapEntry(k.toString(), v),
    );

    for (final entry in threads.entries) {
      final threadId = entry.key.trim();
      if (threadId.isEmpty) continue;

      final threadMap = entry.value is Map
          ? (entry.value as Map).map((k, v) => MapEntry(k.toString(), v))
          : <String, dynamic>{};

      final participantsRaw = threadMap['participants'];
      final participants = participantsRaw is Map
          ? participantsRaw.map((k, v) => MapEntry(k.toString(), v))
          : <String, dynamic>{};

      String peerUid = '';
      for (final p in participants.entries) {
        if (p.key.trim().isEmpty) continue;
        if (p.key.trim() == uid) continue;
        if (p.value == true) {
          peerUid = p.key.trim();
          break;
        }
      }

      final existingRaw = indexRoot[threadId];
      final existing = existingRaw is Map
          ? existingRaw.map((k, v) => MapEntry(k.toString(), v))
          : <String, dynamic>{};
      final isGroup = threadMap['isGroup'] == true;
      final groupName = (threadMap['groupName'] ?? '').toString();
      final groupPicUrl = (threadMap['groupPicUrl'] ?? '').toString();
      final participantCount = participants.entries
          .where((e) => e.key.trim().isNotEmpty && e.value == true)
          .length;

      if (peerUid.isEmpty) {
        peerUid = (existing['peerUid'] ?? '').toString().trim();
      }

      final userLabel = await fetchUserLabel(db, peerUid);
      final peerNameSeed = (existing['peerName'] ?? '').toString().trim();
      final peerRoleSeed = (existing['peerRole'] ?? '').toString().trim();
      final peerName = peerNameSeed.isEmpty
          ? (userLabel['name'] ?? 'User')
          : peerNameSeed;
      final peerRole = await resolveUserRole(
        db,
        peerUid,
        seedRole: peerRoleSeed.isEmpty ? userLabel['role'] ?? '' : peerRoleSeed,
      );

      final currentUnread = existing['unreadCount'];
      final legacyUnread = existing['unread'];
      final unreadCount = currentUnread == null
          ? toInt(legacyUnread)
          : toInt(currentUnread);

      final needsRepair =
          existing.isEmpty ||
          (isGroup && existing['isGroup'] != true) ||
          (isGroup &&
              (existing['groupName'] ?? '').toString().trim().isEmpty) ||
          (isGroup && !existing.containsKey('participantCount')) ||
          (!isGroup && (existing['peerUid'] ?? '').toString().trim().isEmpty) ||
          (existing['updatedAt'] == null) ||
          (existing['subject'] ?? '').toString().trim().isEmpty ||
          (existing['unreadCount'] == null && existing['unread'] != null) ||
          normalizeRole(existing['peerRole']) == 'unknown';

      if (!needsRepair) continue;

      final base = 'mail_index/$uid/$threadId';
      updates['$base/subject'] =
          (existing['subject'] ?? threadMap['subject'] ?? '').toString();
      updates['$base/type'] = (existing['type'] ?? threadMap['type'] ?? 'mail')
          .toString();
      updates['$base/updatedAt'] = toInt(
        existing['updatedAt'] ?? threadMap['updatedAt'],
      );
      updates['$base/lastMessage'] =
          (existing['lastMessage'] ?? threadMap['lastMessage'] ?? '')
              .toString();
      updates['$base/unreadCount'] = unreadCount < 0 ? 0 : unreadCount;
      updates['$base/peerUid'] = peerUid;
      updates['$base/peerName'] = peerName;
      updates['$base/peerRole'] = peerRole;
      updates['$base/isGroup'] = isGroup;
      if (isGroup) {
        updates['$base/groupName'] = groupName;
        updates['$base/groupPicUrl'] = groupPicUrl;
        updates['$base/participantCount'] = participantCount;
      }
      updates['$base/deletedAt'] = existing['deletedAt'];
      touched += 1;
    }

    if (updates.isNotEmpty) {
      await db.ref().update(updates);
    }
    return touched;
  }

  static Future<void> verifyMailWriteOnce({
    required FirebaseDatabase db,
    required String threadId,
    required String senderUid,
    required String receiverUid,
    required String senderName,
    required String receiverName,
    required String senderRole,
    required String receiverRole,
    required String subject,
    required String lastMessage,
    required int now,
    required String type,
  }) async {
    final updates = <String, dynamic>{};
    try {
      final senderIndexPath = 'mail_index/$senderUid/$threadId';
      final receiverIndexPath = 'mail_index/$receiverUid/$threadId';
      final senderIndex = await db.ref(senderIndexPath).get();
      final receiverIndex = await db.ref(receiverIndexPath).get();
      final senderMap = senderIndex.value is Map
          ? (senderIndex.value as Map).map((k, v) => MapEntry(k.toString(), v))
          : <String, dynamic>{};
      final receiverMap = receiverIndex.value is Map
          ? (receiverIndex.value as Map).map(
              (k, v) => MapEntry(k.toString(), v),
            )
          : <String, dynamic>{};

      if (senderMap.isEmpty ||
          (senderMap['peerUid'] ?? '').toString().trim().isEmpty) {
        updates['$senderIndexPath/subject'] = subject;
        updates['$senderIndexPath/type'] = type;
        updates['$senderIndexPath/updatedAt'] = now;
        updates['$senderIndexPath/lastMessage'] = lastMessage;
        updates['$senderIndexPath/unreadCount'] = 0;
        updates['$senderIndexPath/peerUid'] = receiverUid;
        updates['$senderIndexPath/peerName'] = receiverName;
        updates['$senderIndexPath/peerRole'] = normalizeRole(receiverRole);
        updates['$senderIndexPath/deletedAt'] = null;
      }

      if (receiverMap.isEmpty ||
          (receiverMap['peerUid'] ?? '').toString().trim().isEmpty) {
        updates['$receiverIndexPath/subject'] = subject;
        updates['$receiverIndexPath/type'] = type;
        updates['$receiverIndexPath/updatedAt'] = now;
        updates['$receiverIndexPath/lastMessage'] = lastMessage;
        updates['$receiverIndexPath/peerUid'] = senderUid;
        updates['$receiverIndexPath/peerName'] = senderName;
        updates['$receiverIndexPath/peerRole'] = normalizeRole(senderRole);
        updates['$receiverIndexPath/deletedAt'] = null;
      }

      final currentReceiverUnread = toInt(receiverMap['unreadCount']);
      if (currentReceiverUnread <= 0) {
        updates['$receiverIndexPath/unreadCount'] = 1;
      }

      final senderStateSnap = await db
          .ref('mail_state/$senderUid/$threadId')
          .get();
      final receiverStateSnap = await db
          .ref('mail_state/$receiverUid/$threadId')
          .get();

      if (!senderStateSnap.exists) {
        updates['mail_state/$senderUid/$threadId/lastReadAt'] = now;
        updates['mail_state/$senderUid/$threadId/lastDeliveredAt'] = now;
      }
      if (!receiverStateSnap.exists) {
        updates['mail_state/$receiverUid/$threadId/lastDeliveredAt'] = now;
      }

      if (updates.isNotEmpty) {
        await db.ref().update(updates);
      }
    } catch (_) {
      if (updates.isNotEmpty) {
        try {
          await db.ref().update(updates);
        } catch (_) {}
      }
    }
  }

  static Future<int> repairGroupThreadIndex({
    required FirebaseDatabase db,
    required String threadId,
  }) async {
    final safeThreadId = threadId.trim();
    if (safeThreadId.isEmpty) return 0;

    final threadSnap = await db.ref('mail_threads/$safeThreadId').get();
    if (!threadSnap.exists || threadSnap.value is! Map) return 0;

    final thread = (threadSnap.value as Map).map(
      (k, v) => MapEntry(k.toString(), v),
    );
    if (thread['isGroup'] != true) return 0;

    final participantsRaw = thread['participants'];
    final participantsMap = participantsRaw is Map
        ? participantsRaw.map((k, v) => MapEntry(k.toString(), v))
        : <String, dynamic>{};
    final participants = <String>[];
    for (final entry in participantsMap.entries) {
      final uid = entry.key.trim();
      if (uid.isEmpty) continue;
      if (entry.value == true ||
          entry.value == 1 ||
          entry.value.toString() == 'true') {
        participants.add(uid);
      }
    }
    if (participants.isEmpty) return 0;

    final now = DateTime.now().millisecondsSinceEpoch;
    final subject = (thread['subject'] ?? '').toString();
    final type = (thread['type'] ?? 'mail').toString();
    final groupName = (thread['groupName'] ?? '').toString();
    final groupPicUrl = (thread['groupPicUrl'] ?? '').toString();
    final updatedAt = toInt(thread['updatedAt']);
    final lastMessage =
        (thread['lastMessage'] ?? thread['lastMessagePreview'] ?? '')
            .toString();

    final updates = <String, dynamic>{};
    var touched = 0;

    for (final uid in participants) {
      final idxPath = 'mail_index/$uid/$safeThreadId';
      final idxSnap = await db.ref(idxPath).get();
      final idx = idxSnap.value is Map
          ? (idxSnap.value as Map).map((k, v) => MapEntry(k.toString(), v))
          : <String, dynamic>{};

      final needsRepair =
          idx.isEmpty ||
          idx['isGroup'] != true ||
          (idx['groupName'] ?? '').toString().trim().isEmpty ||
          !idx.containsKey('participantCount');

      if (!needsRepair) continue;

      updates['$idxPath/subject'] = (idx['subject'] ?? subject).toString();
      updates['$idxPath/type'] = (idx['type'] ?? type).toString();
      updates['$idxPath/updatedAt'] = toInt(idx['updatedAt']) > 0
          ? toInt(idx['updatedAt'])
          : (updatedAt > 0 ? updatedAt : now);
      updates['$idxPath/lastMessage'] = (idx['lastMessage'] ?? lastMessage)
          .toString();
      updates['$idxPath/unreadCount'] = toInt(idx['unreadCount']);
      updates['$idxPath/deletedAt'] = idx['deletedAt'];
      updates['$idxPath/isGroup'] = true;
      updates['$idxPath/groupName'] = groupName;
      updates['$idxPath/groupPicUrl'] = groupPicUrl;
      updates['$idxPath/participantCount'] = participants.length;
      touched += 1;
    }

    if (updates.isNotEmpty) {
      await db.ref().update(updates);
    }
    return touched;
  }

  static Future<int> runGroupIndexBackfill({
    required FirebaseDatabase db,
  }) async {
    final snap = await db.ref('mail_threads').get();
    if (!snap.exists || snap.value is! Map) return 0;
    final threads = (snap.value as Map).map(
      (k, v) => MapEntry(k.toString(), v),
    );

    var touched = 0;
    for (final entry in threads.entries) {
      final threadId = entry.key.trim();
      if (threadId.isEmpty || entry.value is! Map) continue;
      final map = (entry.value as Map).map((k, v) => MapEntry(k.toString(), v));
      if (map['isGroup'] != true) continue;
      touched += await repairGroupThreadIndex(db: db, threadId: threadId);
    }
    return touched;
  }
}
