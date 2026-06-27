import 'package:firebase_database/firebase_database.dart';

import 'internal_mail_service.dart';
import 'mail_consistency_service.dart';
import 'push_dispatch_service.dart';

enum BookingChangeAction {
  cancelLearner,
  cancelGroup,
  cancelGroupLive,
  rescheduleLearner,
  rescheduleGroup,
  changeSessionSingle,
  changeSessionGroup,
}

class BookingSnapshot {
  const BookingSnapshot({
    required this.courseId,
    required this.courseTitle,
    required this.dayKey,
    required this.time,
    required this.sessionNo,
    required this.teacherId,
    required this.teacherName,
    required this.learnerUids,
    required this.learnerNames,
  });

  final String courseId;
  final String courseTitle;
  final String dayKey;
  final String time;
  final int sessionNo;
  final String teacherId;
  final String teacherName;
  final List<String> learnerUids;
  final List<String> learnerNames;
}

class BookingRecipient {
  const BookingRecipient({
    required this.uid,
    required this.name,
    required this.role,
  });

  final String uid;
  final String name;
  final String role;
}

class BookingCommunicationRequest {
  const BookingCommunicationRequest({
    required this.action,
    required this.actingAdminUid,
    required this.actingAdminName,
    required this.before,
    this.after,
    this.learnerRecipients = const <BookingRecipient>[],
    this.cancelReason,
    this.rescheduleReason,
  });

  final BookingChangeAction action;
  final String actingAdminUid;
  final String actingAdminName;
  final BookingSnapshot before;
  final BookingSnapshot? after;
  final List<BookingRecipient> learnerRecipients;
  final String? cancelReason;
  final String? rescheduleReason;
}

class BookingCommunicationService {
  BookingCommunicationService._();

  static final FirebaseDatabase _db = FirebaseDatabase.instance;

  static Future<void> sendBookingChangeCommunications({
    required BookingCommunicationRequest request,
  }) async {
    final actingAdminUid = request.actingAdminUid.trim();
    if (actingAdminUid.isEmpty) {
      throw Exception('Missing acting admin uid for booking communication.');
    }

    final actingAdminLabel = request.actingAdminName.trim().isNotEmpty
        ? request.actingAdminName.trim()
        : (await MailConsistencyService.fetchUserLabel(
                _db,
                actingAdminUid,
              ))['name'] ??
              'Admin';

    final learnerRecipients = _dedupeRecipients(request.learnerRecipients);
    final teacherRecipients = await _teacherRecipients(request);
    final adminRecipients = await _adminRecipients(
      actingAdminUid: actingAdminUid,
      actingAdminName: actingAdminLabel,
    );

    final subject = _subjectForAction(request.action);
    final pushBody = _pushBody(request);

    for (final recipient in learnerRecipients) {
      await _sendUserCommunication(
        recipient: recipient,
        senderUid: actingAdminUid,
        senderName: actingAdminLabel,
        subject: subject,
        pushBody: pushBody,
        mailBody: _mailBody(request, audience: 'learner'),
        eventParts: [
          request.action.name,
          recipient.uid,
          request.before.courseId,
          request.before.dayKey,
          request.before.time,
          DateTime.now().millisecondsSinceEpoch.toString(),
        ],
        data: _pushData(
          request,
          targetRole: 'learner',
          targetUid: recipient.uid,
        ),
      );
    }

    for (final recipient in teacherRecipients) {
      await _sendUserCommunication(
        recipient: recipient,
        senderUid: actingAdminUid,
        senderName: actingAdminLabel,
        subject: subject,
        pushBody: pushBody,
        mailBody: _mailBody(request, audience: 'teacher'),
        eventParts: [
          request.action.name,
          recipient.uid,
          request.before.courseId,
          request.before.dayKey,
          request.before.time,
          DateTime.now().millisecondsSinceEpoch.toString(),
        ],
        data: _pushData(
          request,
          targetRole: 'teacher',
          targetUid: recipient.uid,
        ),
      );
    }

    final adminUids = adminRecipients.map((e) => e.uid).toList(growable: false);
    await PushDispatchService.dispatchAdminTopic(
      intent: PushIntent.booking,
      title: subject,
      message: pushBody,
      context: const PushDispatchContext(
        screen: 'admin/admin_booking',
        action: 'booking_change_admin_push',
      ),
      eventParts: [
        request.action.name,
        request.before.courseId,
        request.before.dayKey,
        request.before.time,
        DateTime.now().millisecondsSinceEpoch.toString(),
      ],
      fallbackAdminUids: adminUids,
      data: _pushData(request, targetRole: 'admin', targetUid: ''),
    );

    final adminMailBody = _mailBody(request, audience: 'admin');
    for (final admin in adminRecipients) {
      await InternalMailService.sendAutoMail(
        senderUid: actingAdminUid,
        senderName: actingAdminLabel,
        senderRole: 'admin',
        receiverUid: admin.uid,
        receiverName: admin.name,
        receiverRole: 'admin',
        subject: subject,
        body: adminMailBody,
      );
    }
  }

  static Future<void> _sendUserCommunication({
    required BookingRecipient recipient,
    required String senderUid,
    required String senderName,
    required String subject,
    required String pushBody,
    required String mailBody,
    required List<String> eventParts,
    required Map<String, dynamic> data,
  }) async {
    await PushDispatchService.dispatchToUser(
      intent: PushIntent.booking,
      targetUid: recipient.uid,
      title: subject,
      message: pushBody,
      context: const PushDispatchContext(
        screen: 'admin/admin_booking',
        action: 'booking_change_push',
      ),
      eventParts: eventParts,
      data: data,
    );

    await InternalMailService.sendAutoMail(
      senderUid: senderUid,
      senderName: senderName,
      senderRole: 'admin',
      receiverUid: recipient.uid,
      receiverName: recipient.name,
      receiverRole: recipient.role,
      subject: subject,
      body: mailBody,
    );
  }

  static List<BookingRecipient> _dedupeRecipients(
    List<BookingRecipient> recipients,
  ) {
    final byUid = <String, BookingRecipient>{};
    for (final recipient in recipients) {
      final uid = recipient.uid.trim();
      if (uid.isEmpty) {
        continue;
      }
      byUid[uid] = BookingRecipient(
        uid: uid,
        name: recipient.name.trim().isEmpty ? 'User' : recipient.name.trim(),
        role: MailConsistencyService.normalizeRole(recipient.role),
      );
    }
    return byUid.values.toList(growable: false);
  }

  static Future<List<BookingRecipient>> _teacherRecipients(
    BookingCommunicationRequest request,
  ) async {
    final candidates = <BookingRecipient>[
      BookingRecipient(
        uid: request.before.teacherId,
        name: request.before.teacherName,
        role: 'teacher',
      ),
    ];
    if (request.after != null &&
        request.after!.teacherId != request.before.teacherId) {
      candidates.add(
        BookingRecipient(
          uid: request.after!.teacherId,
          name: request.after!.teacherName,
          role: 'teacher',
        ),
      );
    }
    return _dedupeRecipients(candidates);
  }

  static Future<List<BookingRecipient>> _adminRecipients({
    required String actingAdminUid,
    required String actingAdminName,
  }) async {
    final adminUids = await PushDispatchService.loadAdminUids();
    final recipientMap = <String, BookingRecipient>{
      actingAdminUid: BookingRecipient(
        uid: actingAdminUid,
        name: actingAdminName,
        role: 'admin',
      ),
    };

    for (final uid in adminUids) {
      final safeUid = uid.trim();
      if (safeUid.isEmpty || recipientMap.containsKey(safeUid)) {
        continue;
      }
      final label = await MailConsistencyService.fetchUserLabel(_db, safeUid);
      recipientMap[safeUid] = BookingRecipient(
        uid: safeUid,
        name: (label['name'] ?? '').trim().isEmpty
            ? 'Admin'
            : (label['name'] ?? 'Admin'),
        role: 'admin',
      );
    }

    return recipientMap.values.toList(growable: false);
  }

  static String _subjectForAction(BookingChangeAction action) {
    switch (action) {
      case BookingChangeAction.cancelLearner:
      case BookingChangeAction.cancelGroup:
        return 'Booking canceled';
      case BookingChangeAction.cancelGroupLive:
        return '\u26a1 Session Cancelled';
      case BookingChangeAction.rescheduleLearner:
      case BookingChangeAction.rescheduleGroup:
        return 'Booking rescheduled';
      case BookingChangeAction.changeSessionSingle:
      case BookingChangeAction.changeSessionGroup:
        return 'Booking session changed';
    }
  }

  static String _pushBody(BookingCommunicationRequest request) {
    final before = request.before;
    final after = request.after;
    final learnerPart = _learnerSummary(before.learnerNames);
    switch (request.action) {
      case BookingChangeAction.cancelLearner:
      case BookingChangeAction.cancelGroup:
        {
          final reason = request.cancelReason;
          final reasonPart = reason != null
              ? ' Reason: ${_cancelReasonText(reason)}'
              : '';
          return '$learnerPart in ${before.courseTitle} was canceled for ${before.dayKey} at ${before.time}.$reasonPart';
        }
      case BookingChangeAction.cancelGroupLive:
        {
          final reason = request.cancelReason ?? 'other';
          switch (reason) {
            case 'technical':
              return '\u26a1 Your session was cancelled \u2014 teacher had a connectivity issue. No credit used.';
            case 'emergency':
              return '\uD83D\uDEA8 Your session was cancelled due to a teacher emergency. No credit used.';
            default:
              return '\u274C Your session was cancelled by admin. No credit used.';
          }
        }
      case BookingChangeAction.rescheduleLearner:
      case BookingChangeAction.rescheduleGroup:
        {
          final reason = request.rescheduleReason;
          final reasonPart = reason != null
              ? ' Reason: ${_rescheduleReasonText(reason)}'
              : '';
          return '$learnerPart in ${before.courseTitle} moved from ${before.dayKey} ${before.time} to ${after?.dayKey ?? ''} ${after?.time ?? ''}.$reasonPart'
              .trim();
        }
      case BookingChangeAction.changeSessionSingle:
      case BookingChangeAction.changeSessionGroup:
        final reason = request.rescheduleReason;
        final reasonPart = reason != null
            ? ' Reason: ${_rescheduleReasonText(reason)}'
            : '';
        return '$learnerPart in ${before.courseTitle} changed from Session ${before.sessionNo} to Session ${after?.sessionNo ?? before.sessionNo}.$reasonPart';
    }
  }

  static String _mailBody(
    BookingCommunicationRequest request, {
    required String audience,
  }) {
    final before = request.before;
    final after = request.after;

    if (request.action == BookingChangeAction.cancelGroupLive) {
      final reason = request.cancelReason ?? 'other';
      final reasonText = switch (reason) {
        'technical' => 'Teacher had a technical issue (internet/power)',
        'emergency' => 'Teacher had an emergency',
        _ => 'Cancelled by admin',
      };
      final emoji = switch (reason) {
        'technical' => '\u26a1',
        'emergency' => '\uD83D\uDEA8',
        _ => '\u274C',
      };
      final learnerSummary = _learnerSummary(before.learnerNames);

      switch (audience) {
        case 'learner':
          return '''$emoji **Session Cancelled**

Hi there,

Your session has been cancelled.

**Course:** ${before.courseTitle}
**Date:** ${before.dayKey}
**Time:** ${before.time}
**Teacher:** ${before.teacherName}
**Session:** ${_sessionLabel(before.sessionNo)}

**Reason:** $reasonText

\u2705 **No credit was used.** No charge.

Sorry for the inconvenience \uD83D\uDC4F''';
        case 'teacher':
          return '''$emoji **Session Cancelled**

Your session has been cancelled by admin.

**Course:** ${before.courseTitle}
**Date:** ${before.dayKey}
**Time:** ${before.time}
**Learners:** $learnerSummary
**Session:** ${_sessionLabel(before.sessionNo)}

**Reason:** $reasonText''';
        default:
          return '''$emoji **Session Cancelled** \u2014 Admin notice

**Course:** ${before.courseTitle}
**Date:** ${before.dayKey}
**Time:** ${before.time}
**Teacher:** ${before.teacherName}
**Learners:** $learnerSummary
**Session:** ${_sessionLabel(before.sessionNo)}

**Reason:** $reasonText

**Cancelled by:** ${request.actingAdminName.trim().isEmpty ? 'Admin' : request.actingAdminName.trim()}''';
      }
    }

    final lines = <String>[
      _subjectForAction(request.action),
      '',
      'Course: ${before.courseTitle}',
      'Learner${before.learnerNames.length == 1 ? '' : 's'}: ${_learnerSummary(before.learnerNames)}',
      'Before: ${before.dayKey} at ${before.time} · ${_sessionLabel(before.sessionNo)} · ${before.teacherName}',
      if (after != null)
        'After: ${after.dayKey} at ${after.time} · ${_sessionLabel(after.sessionNo)} · ${after.teacherName}',
      'Changed by admin: ${request.actingAdminName.trim().isEmpty ? 'Admin' : request.actingAdminName.trim()}',
    ];

    if (audience == 'admin') {
      lines.add('Audience: admin notice');
    }

    switch (request.action) {
      case BookingChangeAction.cancelLearner:
      case BookingChangeAction.cancelGroup:
        if (request.cancelReason != null) {
          lines.add('Reason: ${_cancelReasonText(request.cancelReason!)}');
        }
        lines.add('Status: booking canceled.');
        break;
      case BookingChangeAction.cancelGroupLive:
        break;
      case BookingChangeAction.rescheduleLearner:
      case BookingChangeAction.rescheduleGroup:
        if (request.rescheduleReason != null) {
          lines.add(
            'Reason: ${_rescheduleReasonText(request.rescheduleReason!)}',
          );
        }
        lines.add('Status: booking rescheduled.');
        break;
      case BookingChangeAction.changeSessionSingle:
      case BookingChangeAction.changeSessionGroup:
        if (request.rescheduleReason != null) {
          lines.add(
            'Reason: ${_rescheduleReasonText(request.rescheduleReason!)}',
          );
        }
        lines.add(
          'Status: session number changed while keeping the booking slot.',
        );
        break;
    }

    return lines.join('\n');
  }

  static Map<String, dynamic> _pushData(
    BookingCommunicationRequest request, {
    required String targetRole,
    required String targetUid,
  }) {
    final before = request.before;
    final after = request.after;
    return {
      'bookingAction': request.action.name,
      'targetRole': targetRole,
      if (targetUid.trim().isNotEmpty) 'targetUid': targetUid.trim(),
      'courseId': before.courseId,
      'courseTitle': before.courseTitle,
      'dayKey': after?.dayKey ?? before.dayKey,
      'time': after?.time ?? before.time,
      'sessionNo': (after?.sessionNo ?? before.sessionNo).toString(),
      'oldTeacherId': before.teacherId,
      'newTeacherId': after?.teacherId ?? before.teacherId,
      'learnerUids': before.learnerUids.join(','),
    };
  }

  static String _learnerSummary(List<String> learnerNames) {
    final cleaned = learnerNames
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
    if (cleaned.isEmpty) {
      return 'Learner';
    }
    if (cleaned.length == 1) {
      return cleaned.first;
    }
    if (cleaned.length == 2) {
      return '${cleaned.first} and ${cleaned.last}';
    }
    return '${cleaned.first} and ${cleaned.length - 1} others';
  }

  static String _sessionLabel(int sessionNo) {
    return sessionNo <= 0 ? 'Session -' : 'Session $sessionNo';
  }

  static String _rescheduleReasonText(String reason) {
    return switch (reason) {
      'schedule_conflict' => 'Teacher schedule conflict',
      'student_request' => 'Student request',
      'makeup' => 'Makeup session',
      _ => 'Other reason',
    };
  }

  static String _cancelReasonText(String reason) {
    return switch (reason) {
      'technical' => 'Teacher had a technical issue (internet/power)',
      'emergency' => 'Teacher had an emergency',
      _ => 'Cancelled by admin',
    };
  }
}
