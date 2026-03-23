import 'package:firebase_core/firebase_core.dart';

String toHumanError(
  Object error, {
  String fallback = 'Something went wrong. Please try again.',
}) {
  final raw = error.toString();
  final lower = raw.toLowerCase();

  if (error is FirebaseException) {
    final code = error.code.toLowerCase();
    if (code.contains('permission-denied') ||
        lower.contains('permission denied')) {
      return 'You do not have permission for this action.';
    }
    if (code.contains('network') || lower.contains('network')) {
      return 'Network issue detected. Please check your internet and try again.';
    }
    if (code.contains('unavailable') || lower.contains('unavailable')) {
      return 'Service is temporarily unavailable. Please try again shortly.';
    }
  }

  if (lower.contains('permission denied')) {
    return 'You do not have access to this section right now.';
  }

  if (lower.contains('type') && lower.contains('not a subtype')) {
    return 'We could not read this data right now. Please refresh and try again.';
  }

  if (lower.contains('null check operator used on a null value')) {
    return 'Some information is temporarily unavailable. Please refresh and try again.';
  }

  if (lower.contains('formatexception') ||
      lower.contains('invalid format') ||
      lower.contains('invalid argument')) {
    return 'We hit a data formatting issue. Please refresh and try again.';
  }

  if (lower.contains('invalid firebase database path') ||
      lower.contains('path specified is invalid')) {
    return 'This profile link is currently unavailable. Please refresh and try again.';
  }

  if (lower.contains('socketexception') || lower.contains('timed out')) {
    return 'Could not reach the server. Please check your internet and try again.';
  }

  final cleaned = raw
      .replaceFirst(RegExp(r'^Exception:\s*'), '')
      .replaceFirst(RegExp(r'^\[[^\]]+\]\s*'), '')
      .trim();

  if (cleaned.isEmpty || cleaned == raw) return fallback;
  if (cleaned.length > 160) return fallback;
  return cleaned;
}

String humanizeUiMessage(
  String message, {
  String fallback = 'Something went wrong. Please try again.',
}) {
  final msg = message.trim();
  if (msg.isEmpty) return fallback;

  final lower = msg.toLowerCase();
  final looksTechnical =
      lower.contains('exception') ||
      lower.contains('firebase') ||
      lower.contains('not a subtype') ||
      lower.contains('stack') ||
      lower.contains('[firebase_');

  if (!looksTechnical && msg.length <= 160) return msg;

  final prefix = msg.split(':').first.trim();
  if (prefix.isEmpty || prefix.toLowerCase() == 'failed') return fallback;
  return '$prefix. Please try again.';
}
