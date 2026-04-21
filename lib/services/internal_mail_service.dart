import 'package:firebase_database/firebase_database.dart';

import 'mail_consistency_service.dart';

class InternalMailService {
  InternalMailService._();

  static final FirebaseDatabase _db = FirebaseDatabase.instance;

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
