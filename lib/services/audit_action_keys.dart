class AuditActionKeys {
  AuditActionKeys._();

  static const adminReminderSend = 'admin.reminder.send';

  static const teacherAttendanceSave = 'teacher.attendance.save';
  static const teacherAttendanceUpdate = 'teacher.attendance.update';
  static const teacherHomeworkEdit = 'teacher.homework.edit';
  static const teacherHomeworkReviewPass = 'teacher.homework.review_pass';
  static const teacherHomeworkUnreview = 'teacher.homework.unreview';
  static const teacherMailSend = 'teacher.mail.send';
  static const teacherReportSend = 'teacher.report.send';
  static const teacherProfileUpdate = 'teacher.profile.update';

  static const learnerHomeworkDone = 'learner.homework.done';
  static const learnerHomeworkUndoSubmit = 'learner.homework.undo_submit';
  static const learnerHomeworkSubmit = 'learner.homework.submit';
  static const learnerBookingCreate = 'learner.booking.create';
  static const learnerBookingCancel = 'learner.booking.cancel';
  static const learnerBookingLateCancelCredit =
      'learner.booking.late_cancel_credit_used';
  static const learnerSessionReviewSubmit = 'learner.session_review.submit';
  static const learnerProfileUpdate = 'learner.profile.update';

  static const systemPushFailed = 'system.push.failed';
}

class AuditDomain {
  AuditDomain._();

  static const admin = 'admin';
  static const attendance = 'attendance';
  static const homework = 'homework';
  static const booking = 'booking';
  static const report = 'report';
  static const mail = 'mail';
  static const profile = 'profile';
  static const push = 'push';
}

class AuditResult {
  AuditResult._();

  static const success = 'success';
  static const failed = 'failed';
  static const denied = 'denied';
}

class AuditSeverity {
  AuditSeverity._();

  static const info = 'info';
  static const warn = 'warn';
  static const critical = 'critical';
}
