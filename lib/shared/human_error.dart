import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

String toHumanError(
  Object error, {
  String fallback =
      'Something unexpected happened while processing your request. Please try again.',
}) {
  final raw = error.toString();
  final lower = raw.toLowerCase();

  if (kDebugMode) {
    debugPrint('[HumanError] ${error.runtimeType}: $raw');
  }

  String? byHttpStatus() {
    final m = RegExp(
      r'\bhttp\s*(?:status\s*)?(\d{3})\b',
      caseSensitive: false,
    ).firstMatch(raw);
    if (m == null) return null;
    final code = int.tryParse(m.group(1) ?? '');
    if (code == null) return null;
    return _statusToMessage(code);
  }

  String? byCommonText() {
    if (lower.contains('cancel') ||
        lower.contains('canceled') ||
        lower.contains('cancelled') ||
        lower.contains('aborted by user')) {
      return 'Upload was cancelled.';
    }

    if (lower.contains('load failed')) {
      return 'Data could not be loaded right now. Please check your connection and try again.';
    }

    if (lower.contains('delete failed')) {
      return 'The item could not be deleted right now. Please try again.';
    }

    if (lower.contains('rename failed')) {
      return 'The item could not be renamed. Please try again.';
    }

    if (lower.contains('create folder failed')) {
      return 'The folder could not be created right now. Please try again.';
    }

    if (lower.contains('mail init failed')) {
      return 'The message thread could not be opened right now. Please try again.';
    }

    if (lower.contains('permission denied') ||
        lower.contains('permission-denied') ||
        lower.contains('permission_denied') ||
        lower.contains('not allowed') ||
        lower.contains('access denied')) {
      return 'The app does not have permission to access this file or action.';
    }

    if (lower.contains('expired') ||
        lower.contains('session') ||
        lower.contains('not logged in') ||
        lower.contains('unauthenticated') ||
        lower.contains('invalid token') ||
        lower.contains('auth/id-token-expired') ||
        lower.contains('requires-recent-login')) {
      return 'Your session has expired. Please log in again.';
    }

    if (lower.contains('timed out') ||
        lower.contains('timeout') ||
        lower.contains('deadline exceeded')) {
      return 'The upload took too long and timed out. Please check your internet connection and try again.';
    }

    if (lower.contains('socketexception') ||
        lower.contains('failed host lookup') ||
        lower.contains('network is unreachable') ||
        lower.contains('no address associated with hostname') ||
        lower.contains('connection refused')) {
      return 'No internet connection. Please check your connection and try again.';
    }

    if (lower.contains('connection reset') ||
        lower.contains('broken pipe') ||
        lower.contains('connection aborted') ||
        lower.contains('software caused connection abort')) {
      return 'Your internet connection was interrupted while sending the file. Please try again.';
    }

    if (lower.contains('payload too large') ||
        lower.contains('request entity too large') ||
        lower.contains('too large') ||
        lower.contains('invalid file size') ||
        lower.contains('exceeds max upload size') ||
        lower.contains('upload_err_ini_size') ||
        lower.contains('upload_err_form_size') ||
        lower.contains('file is too large')) {
      return 'This file is too large to upload. Please choose a smaller file.';
    }

    if (lower.contains('unsupported media type') ||
        lower.contains('unsupported file') ||
        lower.contains('unsupported format') ||
        lower.contains('file type is not supported') ||
        lower.contains('only document files are allowed')) {
      return 'This file type is not supported.';
    }

    if (lower.contains('corrupt') ||
        lower.contains('invalid image data') ||
        lower.contains('could not read selected file') ||
        lower.contains('file bytes are empty') ||
        lower.contains('no file path')) {
      return 'This file appears to be unreadable or corrupted. Please choose the file again.';
    }

    if (lower.contains('already exists') ||
        lower.contains('duplicate') ||
        lower.contains('already submitted') ||
        lower.contains('conflict')) {
      return 'This request looks duplicated. Please wait a moment or refresh before trying again.';
    }

    if (lower.contains('invalid json') ||
        lower.contains('server did not return json') ||
        lower.contains('invalid upload response')) {
      return 'The server returned an unexpected response. Please try again in a moment.';
    }

    if (lower.contains('invalid firebase database path') ||
        lower.contains('path specified is invalid')) {
      return 'The requested resource path is invalid. Please refresh and try again.';
    }

    if (lower.contains('type') && lower.contains('not a subtype')) {
      return 'Some data could not be processed correctly. Please refresh and try again.';
    }

    if (lower.contains('null check operator used on a null value')) {
      return 'Some required data is currently unavailable. Please refresh and try again.';
    }

    if (lower.contains('formatexception') ||
        lower.contains('invalid format') ||
        lower.contains('invalid argument')) {
      return 'The submitted data format is not valid. Please review your input and try again.';
    }

    return null;
  }

  final byCode = byHttpStatus();
  if (byCode != null) return byCode;

  final byText = byCommonText();
  if (byText != null) return byText;

  if (error is TimeoutException) {
    return 'The request timed out. Please check your internet connection and try again.';
  }

  if (error is FirebaseException) {
    final code = error.code.toLowerCase();
    if (code.contains('permission-denied')) {
      return 'You do not have permission to perform this action.';
    }
    if (code.contains('network') || code.contains('unavailable')) {
      return 'No internet connection or unstable network detected. Please try again.';
    }
    if (code.contains('unauthenticated') ||
        code.contains('user-token-expired') ||
        code.contains('id-token-expired')) {
      return 'Your session has expired. Please log in again.';
    }
  }

  return fallback;
}

String _statusToMessage(int code) {
  if (code == 400) {
    return 'The request data was not accepted by the server. Please review and try again.';
  }
  if (code == 401) {
    return 'Your session has expired. Please log in again.';
  }
  if (code == 403) {
    return 'You do not have permission to perform this action.';
  }
  if (code == 404) {
    return 'The upload service is not available right now. Please try again later.';
  }
  if (code == 408) {
    return 'The server took too long to respond. Please try again.';
  }
  if (code == 409) {
    return 'This request appears to be duplicated. Please wait and try again.';
  }
  if (code == 413) {
    return 'This file is too large to upload. Please choose a smaller file.';
  }
  if (code == 415) {
    return 'This file type is not supported.';
  }
  if (code == 429) {
    return 'Too many requests were sent in a short time. Please wait and try again.';
  }
  if (code == 500) {
    return 'The server encountered a problem while processing your request. Please try again.';
  }
  if (code == 502 || code == 503) {
    return 'The server is currently unavailable. Please try again later.';
  }
  if (code == 504) {
    return 'The server did not respond in time. Please try again in a moment.';
  }
  if (code >= 500) {
    return 'The server is temporarily busy. Please try again shortly.';
  }
  if (code >= 400) {
    return 'The request could not be completed. Please try again.';
  }
  return 'The request did not complete as expected. Please try again.';
}

String humanizeUiMessage(
  String message, {
  String fallback =
      'Something unexpected happened while processing your request. Please try again.',
}) {
  final msg = message.trim();
  if (msg.isEmpty) return fallback;

  final lower = msg.toLowerCase();
  final hasStackLikeTrace =
      msg.contains('\n#0') ||
      msg.contains('\n#1') ||
      msg.contains('Stack trace') ||
      msg.contains('stacktrace');
  final isClearlyUserFacing =
      msg.length <= 260 &&
      !hasStackLikeTrace &&
      !lower.contains('exception:') &&
      !lower.contains('[firebase_') &&
      !lower.contains('darterror') &&
      !lower.contains('type ') &&
      !lower.contains(' not a subtype ');

  if (isClearlyUserFacing) return msg;

  final looksTechnical =
      lower.contains('exception') ||
      lower.contains('firebase') ||
      lower.startsWith('upload failed') ||
      lower.startsWith('send failed') ||
      lower.startsWith('delete failed') ||
      lower.startsWith('camera upload failed') ||
      lower.startsWith('audio send failed') ||
      lower.startsWith('record failed') ||
      lower.contains('not a subtype') ||
      lower.contains('stack') ||
      lower.contains('[firebase_') ||
      RegExp(r'\bhttp\s*\d{3}\b').hasMatch(lower) ||
      lower.contains('socketexception') ||
      lower.contains('timeout') ||
      lower.contains('timed out');

  if (!looksTechnical && msg.length <= 160) return msg;

  return toHumanError(Exception(msg), fallback: fallback);
}
