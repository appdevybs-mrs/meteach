import 'package:firebase_database/firebase_database.dart';

import 'mail_consistency_service.dart';

class InternalMailService {
  InternalMailService._();

  static final FirebaseDatabase _db = FirebaseDatabase.instance;

  static String _previewFromBody(String body) {
    final clean = body.trim();
    if (clean.isEmpty) return '';
    return clean.length > 80 ? clean.substring(0, 80) : clean;
  }

  static Future<List<String>> loadThreadParticipants(String threadId) async {
    final safeThreadId = threadId.trim();
    if (safeThreadId.isEmpty) return const [];
    final snap = await _db.ref('mail_threads/$safeThreadId/participants').get();
    if (!snap.exists || snap.value is! Map) return const [];
    final map = (snap.value as Map).map((k, v) => MapEntry(k.toString(), v));
    final out = <String>[];
    map.forEach((uid, raw) {
      if ((raw == true || raw == 1 || raw.toString() == 'true') &&
          uid.trim().isNotEmpty) {
        out.add(uid.trim());
      }
    });
    return out;
  }

  static Future<String> createGroupThread({
    required String creatorUid,
    required String creatorName,
    required String creatorRole,
    required Set<String> participantUids,
    required String groupName,
    String? groupPicUrl,
    String? subject,
    required int now,
  }) async {
    final safeCreatorUid = creatorUid.trim();
    final safeGroupName = groupName.trim();
    final safeSubject = (subject ?? groupName).trim();
    final safePic = (groupPicUrl ?? '').trim();
    final participants = <String>{
      safeCreatorUid,
      ...participantUids.map((e) => e.trim()).where((e) => e.isNotEmpty),
    };

    if (safeCreatorUid.isEmpty ||
        safeGroupName.isEmpty ||
        safeSubject.isEmpty) {
      throw Exception('Missing group creator, name, or subject.');
    }
    if (participants.length < 2) {
      throw Exception('Group must contain at least two participants.');
    }

    final threadId = _db.ref('mail_threads').push().key;
    if (threadId == null || threadId.trim().isEmpty) {
      throw Exception('Failed to create group thread id.');
    }

    final updates = <String, dynamic>{
      'mail_threads/$threadId/subject': safeSubject,
      'mail_threads/$threadId/type': 'mail',
      'mail_threads/$threadId/isGroup': true,
      'mail_threads/$threadId/groupName': safeGroupName,
      'mail_threads/$threadId/groupPicUrl': safePic,
      'mail_threads/$threadId/createdByUid': safeCreatorUid,
      'mail_threads/$threadId/createdAt': now,
      'mail_threads/$threadId/updatedAt': now,
      'mail_threads/$threadId/lastMessage': '',
    };

    for (final uid in participants) {
      updates['mail_threads/$threadId/participants/$uid'] = true;
      updates['mail_index/$uid/$threadId/subject'] = safeSubject;
      updates['mail_index/$uid/$threadId/type'] = 'mail';
      updates['mail_index/$uid/$threadId/isGroup'] = true;
      updates['mail_index/$uid/$threadId/groupName'] = safeGroupName;
      updates['mail_index/$uid/$threadId/groupPicUrl'] = safePic;
      updates['mail_index/$uid/$threadId/participantCount'] =
          participants.length;
      updates['mail_index/$uid/$threadId/updatedAt'] = now;
      updates['mail_index/$uid/$threadId/lastMessage'] = '';
      updates['mail_index/$uid/$threadId/unreadCount'] = 0;
      updates['mail_index/$uid/$threadId/deletedAt'] = null;
      updates['mail_state/$uid/$threadId/lastDeliveredAt'] = now;
      if (uid == safeCreatorUid) {
        updates['mail_state/$uid/$threadId/lastReadAt'] = now;
      }
    }

    await _db.ref().update(updates);
    return threadId;
  }

  static Future<void> sendGroupMessage({
    required String threadId,
    required String senderUid,
    required String body,
    List<Map<String, dynamic>> attachments = const [],
  }) async {
    final safeThreadId = threadId.trim();
    final safeSenderUid = senderUid.trim();
    final safeBody = body.trim();
    if (safeThreadId.isEmpty || safeSenderUid.isEmpty || safeBody.isEmpty) {
      throw Exception('Missing group message payload.');
    }

    final participants = await loadThreadParticipants(safeThreadId);
    if (participants.isEmpty) throw Exception('Thread has no participants.');
    if (!participants.contains(safeSenderUid)) {
      throw Exception('Sender is not a participant in this thread.');
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final msgRef = _db.ref('mail_messages/$safeThreadId').push();
    final msgKey = msgRef.key;
    if (msgKey == null || msgKey.trim().isEmpty) {
      throw Exception('Failed to create internal group message id.');
    }
    final preview = _previewFromBody(safeBody);

    final toUids = <String, bool>{
      for (final uid in participants)
        if (uid != safeSenderUid) uid: true,
    };

    final updates = <String, dynamic>{
      'mail_messages/$safeThreadId/$msgKey': {
        'fromUid': safeSenderUid,
        'body': safeBody,
        'toUids': toUids,
        'ccUids': <String, bool>{},
        'bccUids': <String, bool>{},
        'attachments': attachments,
        'createdAt': now,
        'deletedFor': <String, bool>{},
      },
      'mail_threads/$safeThreadId/updatedAt': now,
      'mail_threads/$safeThreadId/lastMessage': preview,
      'mail_state/$safeSenderUid/$safeThreadId/lastReadAt': now,
      'mail_state/$safeSenderUid/$safeThreadId/lastDeliveredAt': now,
    };

    for (final uid in participants) {
      updates['mail_threads/$safeThreadId/participants/$uid'] = true;
      updates['mail_index/$uid/$safeThreadId/updatedAt'] = now;
      updates['mail_index/$uid/$safeThreadId/lastMessage'] = preview;
      updates['mail_index/$uid/$safeThreadId/deletedAt'] = null;
      updates['mail_index/$uid/$safeThreadId/participantCount'] =
          participants.length;
      if (uid == safeSenderUid) {
        updates['mail_index/$uid/$safeThreadId/unreadCount'] = 0;
      } else {
        updates['mail_index/$uid/$safeThreadId/unreadCount'] =
            ServerValue.increment(1);
        updates['mail_state/$uid/$safeThreadId/lastDeliveredAt'] = now;
      }
    }

    await _db.ref().update(updates);
  }

  static Future<void> addGroupMembers({
    required String threadId,
    required Set<String> memberUids,
  }) async {
    final safeThreadId = threadId.trim();
    if (safeThreadId.isEmpty) throw Exception('Missing thread id.');
    final members = memberUids
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet();
    if (members.isEmpty) return;

    final threadSnap = await _db.ref('mail_threads/$safeThreadId').get();
    if (!threadSnap.exists || threadSnap.value is! Map) {
      throw Exception('Thread not found.');
    }
    final thread = (threadSnap.value as Map).map(
      (k, v) => MapEntry(k.toString(), v),
    );
    final isGroup = thread['isGroup'] == true;
    if (!isGroup) throw Exception('Not a group thread.');
    final subject = (thread['subject'] ?? '').toString();
    final groupName = (thread['groupName'] ?? '').toString();
    final groupPicUrl = (thread['groupPicUrl'] ?? '').toString();

    final existing = await loadThreadParticipants(safeThreadId);
    final allMembers = <String>{...existing, ...members};
    final now = DateTime.now().millisecondsSinceEpoch;
    final updates = <String, dynamic>{
      'mail_threads/$safeThreadId/updatedAt': now,
    };

    for (final uid in allMembers) {
      updates['mail_threads/$safeThreadId/participants/$uid'] = true;
      updates['mail_index/$uid/$safeThreadId/subject'] = subject;
      updates['mail_index/$uid/$safeThreadId/type'] = 'mail';
      updates['mail_index/$uid/$safeThreadId/isGroup'] = true;
      updates['mail_index/$uid/$safeThreadId/groupName'] = groupName;
      updates['mail_index/$uid/$safeThreadId/groupPicUrl'] = groupPicUrl;
      updates['mail_index/$uid/$safeThreadId/participantCount'] =
          allMembers.length;
      updates['mail_index/$uid/$safeThreadId/updatedAt'] = now;
      updates['mail_index/$uid/$safeThreadId/deletedAt'] = null;
      updates['mail_state/$uid/$safeThreadId/lastDeliveredAt'] = now;
    }
    await _db.ref().update(updates);
  }

  static Future<void> removeGroupMember({
    required String threadId,
    required String memberUid,
  }) async {
    final safeThreadId = threadId.trim();
    final safeMemberUid = memberUid.trim();
    if (safeThreadId.isEmpty || safeMemberUid.isEmpty) {
      throw Exception('Missing thread or member.');
    }
    final threadSnap = await _db.ref('mail_threads/$safeThreadId').get();
    if (!threadSnap.exists || threadSnap.value is! Map) {
      throw Exception('Thread not found.');
    }
    final thread = (threadSnap.value as Map).map(
      (k, v) => MapEntry(k.toString(), v),
    );
    if (thread['isGroup'] != true) {
      throw Exception('Not a group thread.');
    }
    final creatorUid = (thread['createdByUid'] ?? '').toString().trim();
    if (creatorUid.isNotEmpty && creatorUid == safeMemberUid) {
      throw Exception('Group creator cannot be removed.');
    }

    final existing = await loadThreadParticipants(safeThreadId);
    if (!existing.contains(safeMemberUid)) return;
    final updates = <String, dynamic>{
      'mail_threads/$safeThreadId/participants/$safeMemberUid': null,
      'mail_index/$safeMemberUid/$safeThreadId': null,
      'mail_state/$safeMemberUid/$safeThreadId': null,
      'mail_threads/$safeThreadId/updatedAt':
          DateTime.now().millisecondsSinceEpoch,
    };
    await _db.ref().update(updates);

    final remaining = await loadThreadParticipants(safeThreadId);
    final count = remaining.length;
    if (count > 0) {
      final fix = <String, dynamic>{};
      for (final uid in remaining) {
        fix['mail_index/$uid/$safeThreadId/participantCount'] = count;
      }
      await _db.ref().update(fix);
    }
  }

  static Future<void> archiveGroupThreadForEveryone({
    required String threadId,
    required String actorUid,
    required String actorRole,
  }) async {
    final safeThreadId = threadId.trim();
    final safeActorUid = actorUid.trim();
    final normalizedRole = MailConsistencyService.normalizeRole(actorRole);
    if (safeThreadId.isEmpty || safeActorUid.isEmpty) {
      throw Exception('Missing thread or actor uid.');
    }
    if (normalizedRole != 'admin') {
      throw Exception('Only admin can archive/delete a group.');
    }

    final threadSnap = await _db.ref('mail_threads/$safeThreadId').get();
    if (!threadSnap.exists || threadSnap.value is! Map) {
      throw Exception('Thread not found.');
    }
    final thread = (threadSnap.value as Map).map(
      (k, v) => MapEntry(k.toString(), v),
    );
    if (thread['isGroup'] != true) {
      throw Exception('Not a group thread.');
    }

    final participants = await loadThreadParticipants(safeThreadId);
    final now = DateTime.now().millisecondsSinceEpoch;
    final updates = <String, dynamic>{
      'mail_threads/$safeThreadId/archivedAt': now,
      'mail_threads/$safeThreadId/archivedByUid': safeActorUid,
      'mail_threads/$safeThreadId/archivedReason': 'group_deleted_by_admin',
      'mail_threads/$safeThreadId/isDeleted': true,
      'mail_threads/$safeThreadId/updatedAt': now,
    };

    for (final uid in participants) {
      updates['mail_threads/$safeThreadId/participants/$uid'] = null;
      updates['mail_index/$uid/$safeThreadId'] = null;
      updates['mail_state/$uid/$safeThreadId'] = null;
    }

    await _db.ref().update(updates);
  }

  static Future<String> ensureOneToOneThread({
    required String senderUid,
    required String senderName,
    required String senderRole,
    required String receiverUid,
    required String receiverName,
    required String receiverRole,
    required String subject,
    required int now,
  }) async {
    final safeSenderUid = senderUid.trim();
    final safeReceiverUid = receiverUid.trim();
    final safeSubject = subject.trim();

    if (safeSenderUid.isEmpty ||
        safeReceiverUid.isEmpty ||
        safeSubject.isEmpty) {
      throw Exception(
        'Missing sender, receiver, or subject for internal mail.',
      );
    }

    final indexSnap = await _db.ref('mail_index/$safeSenderUid').get();
    final indexMap = indexSnap.value is Map
        ? (indexSnap.value as Map).map((k, v) => MapEntry(k.toString(), v))
        : <String, dynamic>{};

    for (final entry in indexMap.entries) {
      final raw = entry.value;
      if (raw is! Map) continue;
      final map = raw.map((k, v) => MapEntry(k.toString(), v));
      final peerUid = (map['peerUid'] ?? '').toString().trim();
      final deletedAt = map['deletedAt'];
      final existingSubject = (map['subject'] ?? '').toString().trim();
      if (deletedAt != null) continue;
      if (peerUid == safeReceiverUid && existingSubject == safeSubject) {
        return entry.key;
      }
    }

    final threadId = _db.ref('mail_threads').push().key;
    if (threadId == null || threadId.trim().isEmpty) {
      throw Exception('Failed to create internal mail thread id.');
    }

    final participants = <String, bool>{safeSenderUid: true};
    if (safeReceiverUid != safeSenderUid) {
      participants[safeReceiverUid] = true;
    }

    final updates = <String, dynamic>{
      'mail_threads/$threadId/subject': safeSubject,
      'mail_threads/$threadId/type': 'mail',
      'mail_threads/$threadId/createdAt': now,
      'mail_threads/$threadId/updatedAt': now,
      'mail_threads/$threadId/lastMessage': '',
      'mail_threads/$threadId/participants': participants,
      'mail_index/$safeSenderUid/$threadId/subject': safeSubject,
      'mail_index/$safeSenderUid/$threadId/type': 'mail',
      'mail_index/$safeSenderUid/$threadId/updatedAt': now,
      'mail_index/$safeSenderUid/$threadId/lastMessage': '',
      'mail_index/$safeSenderUid/$threadId/unreadCount': 0,
      'mail_index/$safeSenderUid/$threadId/peerUid': safeReceiverUid,
      'mail_index/$safeSenderUid/$threadId/peerName': receiverName,
      'mail_index/$safeSenderUid/$threadId/peerRole':
          MailConsistencyService.normalizeRole(receiverRole),
      'mail_index/$safeSenderUid/$threadId/deletedAt': null,
      'mail_state/$safeSenderUid/$threadId/lastReadAt': now,
      'mail_state/$safeSenderUid/$threadId/lastDeliveredAt': now,
    };

    if (safeReceiverUid != safeSenderUid) {
      updates['mail_index/$safeReceiverUid/$threadId/subject'] = safeSubject;
      updates['mail_index/$safeReceiverUid/$threadId/type'] = 'mail';
      updates['mail_index/$safeReceiverUid/$threadId/updatedAt'] = now;
      updates['mail_index/$safeReceiverUid/$threadId/lastMessage'] = '';
      updates['mail_index/$safeReceiverUid/$threadId/unreadCount'] = 0;
      updates['mail_index/$safeReceiverUid/$threadId/peerUid'] = safeSenderUid;
      updates['mail_index/$safeReceiverUid/$threadId/peerName'] = senderName;
      updates['mail_index/$safeReceiverUid/$threadId/peerRole'] =
          MailConsistencyService.normalizeRole(senderRole);
      updates['mail_index/$safeReceiverUid/$threadId/deletedAt'] = null;
      updates['mail_state/$safeReceiverUid/$threadId/lastDeliveredAt'] = now;
    }

    await _db.ref().update(updates);
    return threadId;
  }

  static Future<String> sendAutoMail({
    required String senderUid,
    required String senderName,
    required String senderRole,
    required String receiverUid,
    required String receiverName,
    required String receiverRole,
    required String subject,
    required String body,
  }) async {
    final safeBody = body.trim();
    if (safeBody.isEmpty) {
      throw Exception('Internal mail body cannot be empty.');
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final threadId = await ensureOneToOneThread(
      senderUid: senderUid,
      senderName: senderName,
      senderRole: senderRole,
      receiverUid: receiverUid,
      receiverName: receiverName,
      receiverRole: receiverRole,
      subject: subject,
      now: now,
    );

    final msgRef = _db.ref('mail_messages/$threadId').push();
    final msgKey = msgRef.key;
    if (msgKey == null || msgKey.trim().isEmpty) {
      throw Exception('Failed to create internal mail message id.');
    }

    final preview = safeBody.length > 80 ? safeBody.substring(0, 80) : safeBody;
    final safeSenderUid = senderUid.trim();
    final safeReceiverUid = receiverUid.trim();
    final sameUser = safeSenderUid == safeReceiverUid;

    final updates = <String, dynamic>{
      'mail_messages/$threadId/$msgKey': {
        'fromUid': safeSenderUid,
        'body': safeBody,
        'toUids': {safeReceiverUid: true},
        'ccUids': <String, bool>{},
        'bccUids': <String, bool>{},
        'attachments': <Map<String, String>>[],
        'createdAt': now,
        'deletedFor': <String, bool>{},
      },
      'mail_threads/$threadId/updatedAt': now,
      'mail_threads/$threadId/lastMessage': preview,
      'mail_threads/$threadId/participants/$safeSenderUid': true,
      'mail_index/$safeSenderUid/$threadId/subject': subject,
      'mail_index/$safeSenderUid/$threadId/type': 'mail',
      'mail_index/$safeSenderUid/$threadId/updatedAt': now,
      'mail_index/$safeSenderUid/$threadId/lastMessage': preview,
      'mail_index/$safeSenderUid/$threadId/unreadCount': 0,
      'mail_index/$safeSenderUid/$threadId/peerUid': safeReceiverUid,
      'mail_index/$safeSenderUid/$threadId/peerName': receiverName,
      'mail_index/$safeSenderUid/$threadId/peerRole':
          MailConsistencyService.normalizeRole(receiverRole),
      'mail_index/$safeSenderUid/$threadId/deletedAt': null,
      'mail_state/$safeSenderUid/$threadId/lastReadAt': now,
      'mail_state/$safeSenderUid/$threadId/lastDeliveredAt': now,
    };

    if (sameUser) {
      updates['mail_index/$safeSenderUid/$threadId/unreadCount'] = 1;
      updates['mail_state/$safeSenderUid/$threadId/lastReadAt'] = null;
    } else {
      updates['mail_threads/$threadId/participants/$safeReceiverUid'] = true;
      updates['mail_index/$safeReceiverUid/$threadId/subject'] = subject;
      updates['mail_index/$safeReceiverUid/$threadId/type'] = 'mail';
      updates['mail_index/$safeReceiverUid/$threadId/updatedAt'] = now;
      updates['mail_index/$safeReceiverUid/$threadId/lastMessage'] = preview;
      updates['mail_index/$safeReceiverUid/$threadId/unreadCount'] =
          ServerValue.increment(1);
      updates['mail_index/$safeReceiverUid/$threadId/peerUid'] = safeSenderUid;
      updates['mail_index/$safeReceiverUid/$threadId/peerName'] = senderName;
      updates['mail_index/$safeReceiverUid/$threadId/peerRole'] =
          MailConsistencyService.normalizeRole(senderRole);
      updates['mail_index/$safeReceiverUid/$threadId/deletedAt'] = null;
      updates['mail_state/$safeReceiverUid/$threadId/lastDeliveredAt'] = now;
    }

    await _db.ref().update(updates);

    if (!sameUser) {
      await MailConsistencyService.verifyMailWriteOnce(
        db: _db,
        threadId: threadId,
        senderUid: safeSenderUid,
        receiverUid: safeReceiverUid,
        senderName: senderName,
        receiverName: receiverName,
        senderRole: senderRole,
        receiverRole: receiverRole,
        subject: subject,
        lastMessage: preview,
        now: now,
        type: 'mail',
      );
    }

    return threadId;
  }
}
