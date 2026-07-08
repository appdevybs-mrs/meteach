import 'dart:convert';

import 'package:firebase_database/firebase_database.dart';

enum PromoCheckStatus {
  valid,
  empty,
  invalid,
  disabled,
  expiredDate,
  expiredUsage,
  alreadyUsed,
}

class PromoCheckResult {
  const PromoCheckResult({
    required this.status,
    this.promo = const <String, dynamic>{},
    this.usedCount = 0,
  });

  final PromoCheckStatus status;
  final Map<String, dynamic> promo;
  final int usedCount;

  bool get isValid => status == PromoCheckStatus.valid;

  String get message {
    switch (status) {
      case PromoCheckStatus.valid:
        return 'Promo code applied. | تم تطبيق كود الخصم.';
      case PromoCheckStatus.empty:
        return 'Enter a promo code first. | أدخل كود الخصم أولا.';
      case PromoCheckStatus.expiredDate:
        return 'This promo code has expired. | انتهت صلاحية كود الخصم.';
      case PromoCheckStatus.expiredUsage:
        return 'This promo code has reached its usage limit. | وصل كود الخصم إلى الحد الأقصى للاستخدام.';
      case PromoCheckStatus.alreadyUsed:
        return 'You have already used this promo code. | لقد استخدمت كود الخصم هذا من قبل.';
      case PromoCheckStatus.disabled:
      case PromoCheckStatus.invalid:
        return 'Promo code is not valid for this study type. | كود الخصم غير صالح لهذا النوع من الدراسة.';
    }
  }
}

class PromoReservation {
  const PromoReservation({
    required this.success,
    required this.check,
    this.usedCountAfterApply = 0,
    this.claimKeys = const <String>[],
  });

  final bool success;
  final PromoCheckResult check;
  final int usedCountAfterApply;
  final List<String> claimKeys;
}

class PromoRedemptionService {
  const PromoRedemptionService._();

  static String normalizeCode(String raw) => raw.trim().toUpperCase();

  static String storageDeliveryKey(String raw) {
    switch (raw.trim().toLowerCase()) {
      case 'flexible':
      case 'online':
        return 'online';
      case 'private':
      case 'live':
        return 'live';
      case 'inclass':
      case 'in-class':
      case 'in class':
      case 'in_class':
        return 'inclass';
      case 'recorded':
        return 'recorded';
      default:
        return raw.trim().toLowerCase();
    }
  }

  static String normalizedEmail(String raw) => raw.trim().toLowerCase();

  static String normalizedPhone(String raw) =>
      raw.replaceAll(RegExp(r'\D+'), '');

  static List<String> identityKeys({
    String uid = '',
    String email = '',
    String phone = '',
  }) {
    final out = <String>[];
    final e = normalizedEmail(email);
    final p = normalizedPhone(phone);
    final u = uid.trim();
    if (e.isNotEmpty) out.add('email_${_keySafe(e)}');
    if (p.isNotEmpty) out.add('phone_$p');
    if (u.isNotEmpty) out.add('uid_${_keySafe(u)}');
    return out;
  }

  static Future<PromoCheckResult> checkPromo({
    required String courseId,
    required String deliveryKey,
    required String code,
    required String email,
    required String phone,
    String uid = '',
  }) async {
    final normalizedCode = normalizeCode(code);
    if (normalizedCode.isEmpty) {
      return const PromoCheckResult(status: PromoCheckStatus.empty);
    }

    final db = FirebaseDatabase.instance;
    final promoSnap = await db
        .ref(
          'courses/$courseId/delivery_configs/${storageDeliveryKey(deliveryKey)}/promo_codes/$normalizedCode',
        )
        .get();
    final promo = _asMap(promoSnap.value);
    if (promo.isEmpty) {
      return const PromoCheckResult(status: PromoCheckStatus.invalid);
    }

    final counterSnap = await db
        .ref('promo_usage_counters/$normalizedCode/usedCount')
        .get();
    final usedCount = _asInt(counterSnap.value) ?? 0;
    final baseStatus = _statusForPromo(promo, usedCount);
    if (baseStatus != PromoCheckStatus.valid) {
      return PromoCheckResult(
        status: baseStatus,
        promo: promo,
        usedCount: usedCount,
      );
    }

    final keys = identityKeys(uid: uid, email: email, phone: phone);
    for (final key in keys) {
      final claimSnap = await db.ref('promo_claims/$normalizedCode/$key').get();
      if (claimSnap.exists) {
        return PromoCheckResult(
          status: PromoCheckStatus.alreadyUsed,
          promo: promo,
          usedCount: usedCount,
        );
      }
    }

    return PromoCheckResult(
      status: PromoCheckStatus.valid,
      promo: promo,
      usedCount: usedCount,
    );
  }

  static Future<PromoReservation> reservePromoUse({
    required String courseId,
    required String courseTitle,
    required String deliveryKey,
    required String code,
    required String email,
    required String phone,
    required String fullName,
    required String subscriptionId,
    String uid = '',
  }) async {
    final normalizedCode = normalizeCode(code);
    final initial = await checkPromo(
      courseId: courseId,
      deliveryKey: deliveryKey,
      code: normalizedCode,
      email: email,
      phone: phone,
      uid: uid,
    );
    if (!initial.isValid) {
      return PromoReservation(success: false, check: initial);
    }

    final db = FirebaseDatabase.instance;
    final counterRef = db.ref('promo_usage_counters/$normalizedCode');
    int usedAfter = initial.usedCount;
    final tx = await counterRef.runTransaction((Object? currentData) {
      final node = _asMap(currentData);
      final currentUsed = _asInt(node['usedCount']) ?? 0;
      final status = _statusForPromo(initial.promo, currentUsed);
      if (status != PromoCheckStatus.valid) return Transaction.abort();
      node['usedCount'] = currentUsed + 1;
      node['updatedAt'] = ServerValue.timestamp;
      usedAfter = currentUsed + 1;
      return Transaction.success(node);
    });

    if (!tx.committed) {
      final after = await checkPromo(
        courseId: courseId,
        deliveryKey: deliveryKey,
        code: normalizedCode,
        email: email,
        phone: phone,
        uid: uid,
      );
      return PromoReservation(success: false, check: after);
    }

    final keys = identityKeys(uid: uid, email: email, phone: phone);
    final claim = <String, dynamic>{
      'subscriptionId': subscriptionId,
      'courseId': courseId,
      'courseTitle': courseTitle,
      'deliveryKey': deliveryKey,
      'promoCode': normalizedCode,
      'fullName': fullName,
      'email': normalizedEmail(email),
      'phone': normalizedPhone(phone),
      'uid': uid.trim(),
      'createdAt': ServerValue.timestamp,
    };
    final updates = <String, dynamic>{};
    for (final key in keys) {
      updates['promo_claims/$normalizedCode/$key'] = claim;
    }
    if (updates.isNotEmpty) await db.ref().update(updates);

    return PromoReservation(
      success: true,
      check: PromoCheckResult(
        status: PromoCheckStatus.valid,
        promo: initial.promo,
        usedCount: initial.usedCount,
      ),
      usedCountAfterApply: usedAfter,
      claimKeys: keys,
    );
  }

  static PromoCheckStatus _statusForPromo(
    Map<String, dynamic> promo,
    int usedCount,
  ) {
    if (promo.isEmpty) return PromoCheckStatus.invalid;
    if (promo['enabled'] == false) return PromoCheckStatus.disabled;
    final expiresAt = _asInt(promo['expiresAt'] ?? promo['expires_at']);
    if (expiresAt != null && expiresAt > 0) {
      if (DateTime.now().millisecondsSinceEpoch > expiresAt) {
        return PromoCheckStatus.expiredDate;
      }
    }
    final usageLimit = _asInt(promo['usageLimit'] ?? promo['usage_limit']);
    if (usageLimit != null && usageLimit > 0 && usedCount >= usageLimit) {
      return PromoCheckStatus.expiredUsage;
    }
    return PromoCheckStatus.valid;
  }

  static Map<String, dynamic> _asMap(dynamic raw) {
    if (raw is! Map) return <String, dynamic>{};
    return raw.map((key, value) => MapEntry(key.toString(), value));
  }

  static int? _asInt(dynamic raw) {
    if (raw == null) return null;
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return int.tryParse(raw.toString().trim());
  }

  static String _keySafe(String raw) {
    final encoded = base64Url.encode(utf8.encode(raw));
    return encoded.replaceAll('=', '');
  }
}
