import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

import 'audit_action_keys.dart';

class AuditActor {
  const AuditActor({this.uid, this.role, this.name});

  final String? uid;
  final String? role;
  final String? name;
}

class AuditTarget {
  const AuditTarget({this.type, this.id, this.uid, this.name});

  final String? type;
  final String? id;
  final String? uid;
  final String? name;
}

class AuditLogService {
  AuditLogService._();

  static final DatabaseReference _root = FirebaseDatabase.instance.ref();
  static const int _summaryMax = 220;
  static const int _tokenMax = 64;

  static String _safe(String value, {int max = _tokenMax}) {
    final v = value.trim();
    if (v.isEmpty) return '';
    return v.length <= max ? v : v.substring(0, max);
  }

  static String _safeLong(String value, {int max = _summaryMax}) {
    final v = value.trim();
    if (v.isEmpty) return '';
    return v.length <= max ? v : v.substring(0, max);
  }

  static String _slug(String value) {
    final v = value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9._-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    return v;
  }

  static String _dayKeyFromMs(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)}';
  }

  static List<String> _sanitizeList(Iterable<String> raw, {int max = 24}) {
    final seen = <String>{};
    final out = <String>[];
    for (final item in raw) {
      final v = _slug(item);
      if (v.isEmpty || v.length > _tokenMax || seen.contains(v)) continue;
      seen.add(v);
      out.add(v);
      if (out.length >= max) break;
    }
    return out;
  }

  static Future<void> logSuccess({
    required String actionKey,
    required String domain,
    required String summary,
    AuditActor? actor,
    AuditTarget? target,
    Map<String, dynamic>? context,
    Map<String, dynamic>? meta,
    List<String> labels = const <String>[],
    List<String> keywords = const <String>[],
  }) {
    return logEvent(
      actionKey: actionKey,
      domain: domain,
      result: AuditResult.success,
      severity: AuditSeverity.info,
      summary: summary,
      actor: actor,
      target: target,
      context: context,
      meta: meta,
      labels: labels,
      keywords: keywords,
    );
  }

  static Future<void> logFailure({
    required String actionKey,
    required String domain,
    required String summary,
    AuditActor? actor,
    AuditTarget? target,
    Map<String, dynamic>? context,
    Map<String, dynamic>? meta,
    String? errorCode,
    String? errorMessage,
    List<String> labels = const <String>[],
    List<String> keywords = const <String>[],
  }) {
    return logEvent(
      actionKey: actionKey,
      domain: domain,
      result: AuditResult.failed,
      severity: AuditSeverity.warn,
      summary: summary,
      actor: actor,
      target: target,
      context: context,
      meta: meta,
      errorCode: errorCode,
      errorMessage: errorMessage,
      labels: labels,
      keywords: keywords,
    );
  }

  static Future<void> logEvent({
    required String actionKey,
    required String domain,
    required String result,
    required String severity,
    required String summary,
    AuditActor? actor,
    AuditTarget? target,
    Map<String, dynamic>? context,
    Map<String, dynamic>? meta,
    String? errorCode,
    String? errorMessage,
    List<String> labels = const <String>[],
    List<String> keywords = const <String>[],
  }) async {
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final eventId = _root.child('activity_logs').push().key;
      if (eventId == null || eventId.trim().isEmpty) return;

      final actorUid = _safe(
        actor?.uid ?? FirebaseAuth.instance.currentUser?.uid ?? '',
        max: 180,
      );
      final actorRole = _safe(actor?.role ?? 'system', max: 32);
      final actorName = _safe(actor?.name ?? '', max: 120);

      final targetType = _safe(target?.type ?? '', max: 40);
      final targetId = _safe(target?.id ?? '', max: 180);
      final targetUid = _safe(target?.uid ?? '', max: 180);
      final targetName = _safe(target?.name ?? '', max: 120);
      final normalizedAction = _safe(actionKey, max: 90);
      final normalizedDomain = _safe(domain, max: 32);
      final normalizedResult = _safe(result, max: 16);
      final normalizedSeverity = _safe(severity, max: 16);
      final summaryText = _safeLong(summary);

      final allLabels = _sanitizeList(<String>[
        ...labels,
        'role:$actorRole',
        'domain:$normalizedDomain',
        'result:$normalizedResult',
        'severity:$normalizedSeverity',
        'action:$normalizedAction',
      ], max: 32);

      final allKeywords = _sanitizeList(<String>[
        ...keywords,
        actorUid,
        actorName,
        targetUid,
        targetName,
        targetId,
      ], max: 48);

      final event = <String, dynamic>{
        'eventId': eventId,
        'ts': now,
        'actionKey': normalizedAction,
        'domain': normalizedDomain,
        'result': normalizedResult,
        'severity': normalizedSeverity,
        'summary': summaryText,
        'actor': {'uid': actorUid, 'role': actorRole, 'name': actorName},
        'target': {
          'type': targetType,
          'id': targetId,
          'uid': targetUid,
          'name': targetName,
        },
        'labels': allLabels,
        'keywords': allKeywords,
      };

      if (context != null && context.isNotEmpty) {
        event['context'] = context;
      }
      if (meta != null && meta.isNotEmpty) {
        event['meta'] = meta;
      }

      final eCode = _safe(errorCode ?? '', max: 60);
      final eMsg = _safeLong(errorMessage ?? '', max: 500);
      if (eCode.isNotEmpty || eMsg.isNotEmpty) {
        event['error'] = {'code': eCode, 'message': eMsg};
      }

      final dayKey = _dayKeyFromMs(now);
      final targetKey = _slug(
        '${targetType.isEmpty ? 'target' : targetType}_${targetUid.isNotEmpty ? targetUid : targetId}',
      );
      final actorKey = actorUid.isEmpty ? '_unknown' : _slug(actorUid);

      final feed = <String, dynamic>{
        'eventId': eventId,
        'ts': now,
        'summary': summaryText,
        'actionKey': normalizedAction,
        'domain': normalizedDomain,
        'result': normalizedResult,
        'severity': normalizedSeverity,
        'actorUid': actorUid,
        'actorRole': actorRole,
        'actorName': actorName,
        'targetType': targetType,
        'targetId': targetId,
        'targetUid': targetUid,
        'targetName': targetName,
        'labels': allLabels,
        'keywords': allKeywords,
        'searchText': _safeLong(
          [
            summaryText,
            actorName,
            targetName,
            normalizedAction,
            ...allKeywords,
          ].where((e) => e.trim().isNotEmpty).join(' ').toLowerCase(),
          max: 900,
        ),
      };

      final updates = <String, dynamic>{
        'activity_logs/$eventId': event,
        'activity_feed/$dayKey/$eventId': feed,
        'activity_by_actor/$actorKey/$eventId': now,
        'activity_by_action/${_slug(normalizedAction)}/$eventId': now,
        'activity_by_result/${_slug(normalizedResult)}/$eventId': now,
      };

      if (targetKey.isNotEmpty) {
        updates['activity_by_target/$targetKey/$eventId'] = now;
      }
      for (final label in allLabels) {
        updates['activity_by_label/${_slug(label)}/$eventId'] = now;
      }

      await _root.update(updates);
    } catch (_) {
      // Logging should never break user flow.
    }
  }
}
