import 'package:firebase_database/firebase_database.dart';
import 'study_variant.dart';

int financeAsInt(dynamic v) {
  if (v == null) return 0;
  if (v is int) return v;
  if (v is num) return v.toInt();
  final raw = v.toString().trim();
  if (raw.isEmpty) return 0;
  final cleaned = raw.replaceAll(RegExp(r'[^0-9-]'), '');
  if (cleaned.isEmpty || cleaned == '-') return 0;
  return int.tryParse(cleaned) ?? 0;
}

bool financeAsBool(dynamic v) {
  if (v == null) return false;
  if (v is bool) return v;
  final s = v.toString().trim().toLowerCase();
  return s == 'true' || s == '1' || s == 'yes';
}

String financeNormalizeStatus(dynamic v) {
  final s = (v ?? '').toString().trim().toLowerCase();
  if (s == 'done' || s == 'tbpaid' || s == 'split' || s == 'waiting') {
    return s;
  }
  return 'tbpaid';
}

int financeNormalizePercent(dynamic v, {int fallback = 100}) {
  final p = financeAsInt(v);
  if (p <= 0) return fallback;
  if (p > 100) return 100;
  return p;
}

int financeNetOf(int amount, int percent) {
  if (amount <= 0) return 0;
  return ((amount * percent) / 100).round();
}

String financeMethodFrom(Map<String, dynamic> row) {
  final raw = (row['financeMethod'] ?? row['method'] ?? '')
      .toString()
      .trim()
      .toLowerCase();
  if (raw == 'cash') return 'cash';
  if (raw == 'ccp') return 'ccp';
  return 'unspecified';
}

String financeLearnerNameFrom(Map<String, dynamic> row) {
  final n1 = (row['learner_name'] ?? '').toString().trim();
  if (n1.isNotEmpty) return n1;
  final n2 = (row['learnerName'] ?? '').toString().trim();
  if (n2.isNotEmpty) return n2;
  final n3 = (row['name'] ?? '').toString().trim();
  if (n3.isNotEmpty) return n3;
  return '(Unknown learner)';
}

String financeTeacherNameFrom(Map<String, dynamic> row) {
  final t1 = (row['teacherName'] ?? '').toString().trim();
  if (t1.isNotEmpty) return t1;
  final t2 = (row['teacher_name'] ?? '').toString().trim();
  if (t2.isNotEmpty) return t2;
  final t3 = (row['teacher'] ?? '').toString().trim();
  if (t3.isNotEmpty) return t3;

  final variantKey = normalizeVariantKey(
    (row['variantKey'] ?? row['variant'] ?? row['deliveryKey'] ?? '')
        .toString(),
    fallback: 'inclass',
  );
  if (variantKey == 'flexible') return 'Flexible';
  if (variantKey == 'recorded') return 'Recorded';

  return 'Unassigned';
}

String financeTeacherIdFrom(Map<String, dynamic> row) {
  return (row['teacherId'] ?? row['teacher_id'] ?? '').toString().trim();
}

class FinancePaymentAmounts {
  const FinancePaymentAmounts({
    required this.amount,
    required this.status,
    required this.splitPaidStatus,
    required this.payoutAmount,
    required this.waitingAmount,
  });

  final int amount;
  final String status;
  final String? splitPaidStatus;
  final int payoutAmount;
  final int waitingAmount;
}

FinancePaymentAmounts financeAmountsFromPayment(Map<String, dynamic> payment) {
  final amount = financeAsInt(payment['amount']);
  final status = financeNormalizeStatus(payment['financePayoutStatus']);

  if (status != 'split') {
    return FinancePaymentAmounts(
      amount: amount,
      status: status,
      splitPaidStatus: null,
      payoutAmount: amount,
      waitingAmount: 0,
    );
  }

  final splitPaid = financeAsInt(payment['financeSplitPaidAmount']);
  var splitWaiting = financeAsInt(payment['financeSplitWaitingAmount']);
  if (splitWaiting <= 0) splitWaiting = amount - splitPaid;
  final paid = splitPaid.clamp(0, amount);
  final waiting = splitWaiting.clamp(0, amount - paid);
  final splitPaidStatus =
      financeNormalizeStatus(payment['financeSplitPaidStatus']) == 'done'
      ? 'done'
      : 'tbpaid';
  return FinancePaymentAmounts(
    amount: amount,
    status: status,
    splitPaidStatus: splitPaidStatus,
    payoutAmount: paid,
    waitingAmount: waiting,
  );
}

class FinanceAllocationView {
  const FinanceAllocationView({
    required this.allocationId,
    required this.paymentId,
    required this.teacherId,
    required this.teacherName,
    required this.variantKey,
    required this.assignedSessions,
    required this.grossShare,
    required this.teacherPercent,
    required this.schoolPercent,
    required this.teacherNet,
    required this.schoolNet,
    required this.payoutStatus,
    required this.teacherPaid,
    required this.teacherConfirmed,
    required this.pushedAt,
    required this.source,
    required this.isLegacy,
  });

  final String allocationId;
  final String paymentId;
  final String teacherId;
  final String teacherName;
  final String variantKey;
  final int? assignedSessions;
  final int grossShare;
  final int teacherPercent;
  final int schoolPercent;
  final int teacherNet;
  final int schoolNet;
  final String payoutStatus;
  final bool teacherPaid;
  final bool teacherConfirmed;
  final int pushedAt;
  final Map<String, dynamic> source;
  final bool isLegacy;

  String get teacherKey {
    final uid = teacherId.trim();
    if (uid.isNotEmpty) return uid;
    final cleaned = teacherName.trim().toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9]+'),
      '_',
    );
    return cleaned.isEmpty ? 'unassigned' : 'name_$cleaned';
  }

  Map<String, dynamic> toRow() {
    return {
      ...source,
      'paymentAmountOriginal': financeAsInt(source['amount']),
      'amount': grossShare,
      'allocationId': allocationId,
      'paymentId': paymentId,
      'teacherId': teacherId,
      'teacherName': teacherName,
      'assignedSessions': assignedSessions,
      'financeTeacherGross': grossShare,
      'financeTeacherPercent': teacherPercent,
      'financeTeacherNet': teacherNet,
      'financeSchoolNet': schoolNet,
      'financePayoutStatus': payoutStatus,
      'teacherPaid': teacherPaid,
      'teacherConfirmed': teacherConfirmed,
      'financePushedAt': pushedAt,
      'isFinanceAllocation': true,
      'isLegacyFinanceAllocation': isLegacy,
    };
  }
}

List<FinanceAllocationView> financeAllocationsFromPayment(
  Map<String, dynamic> payment,
) {
  final paymentId = (payment['paymentId'] ?? '').toString().trim();
  final variantKey = (payment['variantKey'] ?? payment['variant'] ?? '')
      .toString()
      .trim();
  final paymentAmounts = financeAmountsFromPayment(payment);
  final allocationsRaw = payment['financeAllocations'];
  final out = <FinanceAllocationView>[];

  if (allocationsRaw is Map) {
    final allocationMap = allocationsRaw.map((k, v) => MapEntry('$k', v));
    final sortedKeys = allocationMap.keys.toList()..sort();
    for (final key in sortedKeys) {
      final value = allocationMap[key];
      if (value is! Map) continue;
      final row = value.map((k, v) => MapEntry(k.toString(), v));
      final grossShare = financeAsInt(row['grossShare']);
      final teacherPercent = financeNormalizePercent(
        row['teacherPercent'],
        fallback: financeNormalizePercent(payment['financeTeacherPercent']),
      );
      final teacherNet = financeAsInt(row['teacherNet']) > 0
          ? financeAsInt(row['teacherNet'])
          : financeNetOf(grossShare, teacherPercent);
      final schoolNet = financeAsInt(row['schoolNet']) > 0
          ? financeAsInt(row['schoolNet'])
          : (grossShare - teacherNet).clamp(0, grossShare);
      out.add(
        FinanceAllocationView(
          allocationId: key,
          paymentId: paymentId,
          teacherId: (row['teacherId'] ?? '').toString().trim(),
          teacherName: (row['teacherName'] ?? '').toString().trim().isEmpty
              ? financeTeacherNameFrom(payment)
              : (row['teacherName'] ?? '').toString().trim(),
          variantKey: (row['variantKey'] ?? variantKey).toString().trim(),
          assignedSessions: row['assignedSessions'] == null
              ? null
              : financeAsInt(row['assignedSessions']),
          grossShare: grossShare,
          teacherPercent: teacherPercent,
          schoolPercent: financeAsInt(row['schoolPercent']) > 0
              ? financeAsInt(row['schoolPercent'])
              : (100 - teacherPercent).clamp(0, 100),
          teacherNet: teacherNet,
          schoolNet: schoolNet,
          payoutStatus: financeNormalizeStatus(
            row['payoutStatus'] ?? row['financePayoutStatus'],
          ),
          teacherPaid: financeAsBool(row['teacherPaid']),
          teacherConfirmed: financeAsBool(row['teacherConfirmed']),
          pushedAt: financeAsInt(row['pushedAt']) > 0
              ? financeAsInt(row['pushedAt'])
              : financeAsInt(payment['financePushedAt']),
          source: payment,
          isLegacy: false,
        ),
      );
    }
    if (out.isNotEmpty) return out;
  }

  final gross = financeAsInt(payment['financeTeacherGross']) > 0
      ? financeAsInt(payment['financeTeacherGross'])
      : paymentAmounts.payoutAmount;
  final teacherPercent = financeNormalizePercent(
    payment['financeTeacherPercent'],
  );
  final teacherNet = financeAsInt(payment['financeTeacherNet']) > 0
      ? financeAsInt(payment['financeTeacherNet'])
      : financeNetOf(gross, teacherPercent);
  final schoolNet = financeAsInt(payment['financeSchoolNet']) > 0
      ? financeAsInt(payment['financeSchoolNet'])
      : (gross - teacherNet).clamp(0, gross);

  return [
    FinanceAllocationView(
      allocationId: paymentId.isEmpty ? 'legacy' : 'legacy_$paymentId',
      paymentId: paymentId,
      teacherId: financeTeacherIdFrom(payment),
      teacherName: financeTeacherNameFrom(payment),
      variantKey: variantKey,
      assignedSessions: null,
      grossShare: gross,
      teacherPercent: teacherPercent,
      schoolPercent: (100 - teacherPercent).clamp(0, 100),
      teacherNet: teacherNet,
      schoolNet: schoolNet,
      payoutStatus: financeNormalizeStatus(payment['financePayoutStatus']),
      teacherPaid: financeAsBool(payment['teacherPaid']),
      teacherConfirmed: financeAsBool(payment['teacherConfirmed']),
      pushedAt: financeAsInt(payment['financePushedAt']),
      source: payment,
      isLegacy: true,
    ),
  ];
}

Map<String, dynamic> buildFinanceAllocationPayload({
  required String teacherId,
  required String teacherName,
  required String variantKey,
  required int grossShare,
  required int teacherPercent,
  int? assignedSessions,
  String payoutStatus = 'tbpaid',
}) {
  final normalizedPercent = financeNormalizePercent(teacherPercent);
  final teacherNet = financeNetOf(grossShare, normalizedPercent);
  final schoolNet = grossShare - teacherNet;
  return {
    'teacherId': teacherId.trim(),
    'teacherName': teacherName.trim(),
    'variantKey': variantKey.trim(),
    'assignedSessions': assignedSessions,
    'grossShare': grossShare,
    'teacherPercent': normalizedPercent,
    'schoolPercent': (100 - normalizedPercent).clamp(0, 100),
    'teacherNet': teacherNet,
    'schoolNet': schoolNet,
    'payoutStatus': financeNormalizeStatus(payoutStatus),
    'teacherPaid': false,
    'teacherPaidAt': null,
    'teacherPaidBy': null,
    'teacherConfirmed': false,
    'teacherConfirmedAt': null,
    'teacherConfirmedBy': null,
    'pushedAt': ServerValue.timestamp,
    'pushedBy': 'admin',
    'updatedAt': ServerValue.timestamp,
  };
}

List<int> distributeAmountBySessions({
  required int totalAmount,
  required List<int> assignedSessions,
}) {
  if (totalAmount <= 0 || assignedSessions.isEmpty) {
    return List<int>.filled(assignedSessions.length, 0);
  }
  final totalSessions = assignedSessions.fold<int>(0, (sum, v) => sum + v);
  if (totalSessions <= 0) {
    return List<int>.filled(assignedSessions.length, 0);
  }

  final base = <int>[];
  final remainders = <Map<String, dynamic>>[];
  var allocated = 0;
  for (var i = 0; i < assignedSessions.length; i++) {
    final share = totalAmount * assignedSessions[i];
    final floorAmount = share ~/ totalSessions;
    base.add(floorAmount);
    allocated += floorAmount;
    remainders.add({
      'index': i,
      'remainder': share % totalSessions,
      'sessions': assignedSessions[i],
    });
  }

  var left = totalAmount - allocated;
  remainders.sort((a, b) {
    final remainderCompare = (b['remainder'] as int).compareTo(
      a['remainder'] as int,
    );
    if (remainderCompare != 0) return remainderCompare;
    return (b['sessions'] as int).compareTo(a['sessions'] as int);
  });
  for (var i = 0; i < remainders.length && left > 0; i++) {
    final index = remainders[i]['index'] as int;
    base[index] += 1;
    left -= 1;
  }
  return base;
}
