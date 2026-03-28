DateTime _joinOpenFrom(DateTime start) {
  return start.subtract(const Duration(minutes: 5));
}

DateTime _joinOpenUntil(DateTime start) {
  return start.add(const Duration(minutes: 10));
}

String resolveCourseDeliveryKey(Map<String, dynamic> course) {
  final rootVariant = (course['variantKey'] ?? course['variant'] ?? '')
      .toString()
      .trim()
      .toLowerCase();
  if (rootVariant.isNotEmpty) return rootVariant;

  final classMap = (course['class'] is Map)
      ? Map<String, dynamic>.from(course['class'] as Map)
      : <String, dynamic>{};

  final classVariant = (classMap['variantKey'] ?? classMap['variant'] ?? '')
      .toString()
      .trim()
      .toLowerCase();
  if (classVariant.isNotEmpty) return classVariant;

  return (course['deliveryKey'] ?? '').toString().trim().toLowerCase();
}

String resolveCourseStudyMode(Map<String, dynamic> course) {
  final cls = (course['class'] is Map)
      ? Map<String, dynamic>.from(course['class'] as Map)
      : <String, dynamic>{};
  return (course['studyMode'] ?? cls['studyMode'] ?? '')
      .toString()
      .trim()
      .toLowerCase();
}

bool isPrivateOnlineCourse(Map<String, dynamic> course) {
  if (resolveCourseDeliveryKey(course) != 'private') return false;
  final cls = (course['class'] is Map)
      ? Map<String, dynamic>.from(course['class'] as Map)
      : <String, dynamic>{};
  final classMode = (cls['studyMode'] ?? '').toString().trim().toLowerCase();
  final mode = resolveCourseStudyMode(course);
  final effectiveMode = mode.isNotEmpty ? mode : classMode;
  return effectiveMode == 'online' || effectiveMode.isEmpty;
}

bool canJoinFromStart(DateTime start, {DateTime? now}) {
  final current = now ?? DateTime.now();
  final openFrom = _joinOpenFrom(start);
  final openUntil = _joinOpenUntil(start);
  return !current.isBefore(openFrom) && current.isBefore(openUntil);
}

bool canJoinFromStartMs(int startMs, {DateTime? now}) {
  if (startMs <= 0) return false;
  final start = DateTime.fromMillisecondsSinceEpoch(startMs);
  return canJoinFromStart(start, now: now);
}

DateTime joinOpensAt(DateTime start) => _joinOpenFrom(start);

DateTime joinClosesAt(DateTime start) => _joinOpenUntil(start);

String formatJoinCountdown(Duration diff) {
  var total = diff.inSeconds;
  if (total < 0) total = 0;

  final days = total ~/ 86400;
  final hours = (total % 86400) ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final seconds = total % 60;

  String two(int n) => n < 10 ? '0$n' : '$n';

  if (days > 0) {
    return '${days}d ${two(hours)}h';
  }
  if (hours > 0) {
    return '${hours}h ${two(minutes)}m';
  }
  return '${minutes}m ${two(seconds)}s';
}

String joinButtonLabelForWindow({
  required DateTime openFrom,
  required DateTime openUntil,
  required bool hasMeetLink,
  DateTime? now,
  String actionLabel = 'Join',
  String missingLinkLabel = 'Meet link not set',
  String closedLabel = 'Join window closed',
}) {
  if (!hasMeetLink) return missingLinkLabel;

  final current = now ?? DateTime.now();

  if (current.isBefore(openFrom)) {
    final left = formatJoinCountdown(openFrom.difference(current));
    return '$actionLabel (in $left)';
  }

  if (current.isBefore(openUntil)) {
    final left = formatJoinCountdown(openUntil.difference(current));
    return '$actionLabel ($left left)';
  }

  return closedLabel;
}
