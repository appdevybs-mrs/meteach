import 'study_variant.dart';

int paymentAsInt(dynamic v) {
  if (v == null) return 0;
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse(v.toString().trim()) ?? 0;
}

bool paymentRecordIsPresent(Map<String, dynamic> record) {
  final status = (record['status'] ?? '').toString().trim().toLowerCase();
  if (status == 'present') return true;
  if (record['present'] == true) return true;
  return false;
}

Map<String, Map<String, dynamic>> _latestAttendanceByDate(dynamic attendance) {
  if (attendance is! Map) return {};

  final Map<String, Map<String, dynamic>> byDate = {};

  int ts(dynamic x) {
    if (x is int) return x;
    if (x is num) return x.toInt();
    return int.tryParse(x?.toString() ?? '') ?? 0;
  }

  attendance.forEach((_, value) {
    if (value is! Map) return;
    final rec = value
        .map((k, v) => MapEntry(k.toString(), v))
        .cast<String, dynamic>();

    final date = (rec['date'] ?? '').toString().trim();
    if (date.isEmpty) return;

    final score = ts(rec['updatedAt']) > 0
        ? ts(rec['updatedAt'])
        : ts(rec['createdAt']);

    final old = byDate[date];
    if (old == null) {
      byDate[date] = rec;
      return;
    }

    final oldScore = ts(old['updatedAt']) > 0
        ? ts(old['updatedAt'])
        : ts(old['createdAt']);
    if (score >= oldScore) byDate[date] = rec;
  });

  return byDate;
}

int countPresentUniqueAttendanceDates(dynamic attendance) {
  final byDate = _latestAttendanceByDate(attendance);
  int present = 0;
  for (final rec in byDate.values) {
    if (paymentRecordIsPresent(rec)) present += 1;
  }
  return present;
}

int countHeldUniqueAttendanceDates(dynamic attendance) {
  final byDate = _latestAttendanceByDate(attendance);
  return byDate.length;
}

int countPresentOnlineAttendance(dynamic onlineAttendance) {
  if (onlineAttendance is! Map) return 0;

  bool asBool(dynamic v) {
    if (v is bool) return v;
    final s = (v ?? '').toString().trim().toLowerCase();
    return s == 'true' || s == '1' || s == 'yes';
  }

  int present = 0;
  onlineAttendance.forEach((_, value) {
    if (value is! Map) return;
    final rec = value
        .map((k, v) => MapEntry(k.toString(), v))
        .cast<String, dynamic>();
    if (asBool(rec['present']) || asBool(rec['countedCredit'])) {
      present += 1;
    }
  });
  return present;
}

int normalizeReminderForSessions({
  required int sessionsPaidTotal,
  required int remindBeforeSession,
}) {
  if (sessionsPaidTotal <= 0) return 0;
  var reminder = remindBeforeSession > 0 ? remindBeforeSession : 1;
  if (reminder < 1) reminder = 1;
  if (reminder > sessionsPaidTotal) reminder = sessionsPaidTotal;
  return reminder;
}

int paymentSessionsLeft({
  required int sessionsPaidTotal,
  required int sessionsPresent,
}) {
  final left = sessionsPaidTotal - sessionsPresent;
  return left < 0 ? 0 : left;
}

bool isPaymentDueBySessions({
  required int sessionsPaidTotal,
  required int sessionsPresent,
}) {
  if (sessionsPaidTotal <= 0) return false;
  return sessionsPresent >= sessionsPaidTotal;
}

bool isPaymentWarningBySessions({
  required int sessionsPaidTotal,
  required int sessionsPresent,
  required int remindBeforeSession,
}) {
  if (sessionsPaidTotal <= 0) return false;
  if (isPaymentDueBySessions(
    sessionsPaidTotal: sessionsPaidTotal,
    sessionsPresent: sessionsPresent,
  )) {
    return false;
  }

  final left = paymentSessionsLeft(
    sessionsPaidTotal: sessionsPaidTotal,
    sessionsPresent: sessionsPresent,
  );
  final reminder = normalizeReminderForSessions(
    sessionsPaidTotal: sessionsPaidTotal,
    remindBeforeSession: remindBeforeSession,
  );

  return left > 0 && left <= reminder;
}

bool variantUsesSessionBalance(String variantKey) {
  final v = normalizeVariantKey(variantKey);
  return v == 'inclass' || v == 'private' || v == 'flexible';
}
