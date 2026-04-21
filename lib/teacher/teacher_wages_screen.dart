import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../shared/app_feedback.dart';
import '../shared/app_theme.dart';
import '../shared/finance_allocations.dart';
import '../shared/human_error.dart';
import '../shared/study_variant.dart';
import '../shared/teacher_web_layout.dart';

class TeacherWagesScreen extends StatefulWidget {
  const TeacherWagesScreen({super.key});

  static int asInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is num) return v.toInt();
    final raw = v.toString().trim();
    if (raw.isEmpty) return 0;
    final cleaned = raw.replaceAll(RegExp(r'[^0-9-]'), '');
    if (cleaned.isEmpty || cleaned == '-') return 0;
    return int.tryParse(cleaned) ?? 0;
  }

  static String two(int n) => n.toString().padLeft(2, '0');

  static String fmtYmdFromMs(int ms) {
    if (ms <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  @override
  State<TeacherWagesScreen> createState() => _TeacherWagesScreenState();
}

class _TeacherWagesScreenState extends State<TeacherWagesScreen> {
  @override
  void initState() {
    super.initState();
    appThemeController.addListener(_onThemeChanged);
  }

  @override
  void dispose() {
    appThemeController.removeListener(_onThemeChanged);
    super.dispose();
  }

  void _onThemeChanged() {
    if (!mounted) return;
    setState(() {});
  }

  AppPalette get p => appThemeController.palette;

  String _money(int amount) => '$amount DA';

  static String _courseIdFromPayment(Map<String, dynamic> payment) {
    return (payment['course_id'] ?? payment['courseId'] ?? '')
        .toString()
        .trim();
  }

  static String _learnerUidFromPayment(Map<String, dynamic> payment) {
    return (payment['uid'] ?? payment['learnerUid'] ?? '').toString().trim();
  }

  static String _sessionKey({required String uid, required String courseId}) {
    return '${uid.trim()}|${courseId.trim()}';
  }

  static String _deliveryLabelFromPayment(
    Map<String, dynamic> payment, {
    _TeacherClassMeta? fallback,
  }) {
    final variantKey = normalizeVariantKey(
      (payment['variantKey'] ??
              payment['variant'] ??
              fallback?.variantKey ??
              '')
          .toString(),
      fallback: fallback?.variantKey ?? 'inclass',
    );
    final studyMode = normalizeStudyMode(
      (payment['studyMode'] ??
              payment['study_mode'] ??
              payment['privateStudyMode'] ??
              payment['private_study_mode'] ??
              fallback?.studyMode ??
              '')
          .toString(),
      variantKey: variantKey,
    );
    return variantLabelWithStudyMode(
      variantKey: variantKey,
      studyMode: studyMode,
    );
  }

  static Map<String, _TeacherClassMeta> _classMetaByCourse(dynamic raw) {
    final out = <String, _TeacherClassMeta>{};
    if (raw is! Map) return out;
    final classes = Map<dynamic, dynamic>.from(raw);

    for (final entry in classes.entries) {
      final value = entry.value;
      if (value is! Map) continue;
      final cls = value.map((k, v) => MapEntry(k.toString(), v));
      final courseId = (cls['course_id'] ?? '').toString().trim();
      if (courseId.isEmpty || out.containsKey(courseId)) continue;

      final variantKey = normalizeVariantKey(
        (cls['variantKey'] ?? cls['variant'] ?? '').toString(),
      );
      final studyMode = normalizeStudyMode(
        (cls['studyMode'] ??
                cls['study_mode'] ??
                cls['privateStudyMode'] ??
                cls['private_study_mode'] ??
                '')
            .toString(),
        variantKey: variantKey,
      );

      out[courseId] = _TeacherClassMeta(
        variantKey: variantKey,
        studyMode: studyMode,
      );
    }

    return out;
  }

  static Map<String, _SessionCounts> _attendanceCountsByLearnerCourse({
    required dynamic raw,
    required String teacherId,
  }) {
    final out = <String, _SessionCounts>{};
    if (raw is! Map || teacherId.trim().isEmpty) return out;
    final classes = Map<dynamic, dynamic>.from(raw);

    for (final classEntry in classes.entries) {
      final classValue = classEntry.value;
      if (classValue is! Map) continue;
      final cls = classValue.map((k, v) => MapEntry(k.toString(), v));

      var classTeacherUid = '';
      final instCur = cls['instructor_current'];
      if (instCur is Map) {
        classTeacherUid = (instCur['uid'] ?? '').toString().trim();
      }

      final classMatch =
          classTeacherUid.isNotEmpty && classTeacherUid == teacherId.trim();
      final courseId = (cls['course_id'] ?? '').toString().trim();
      if (courseId.isEmpty) continue;

      final attendanceRaw = cls['attendance'];
      if (attendanceRaw is! Map) continue;
      final attendance = Map<dynamic, dynamic>.from(attendanceRaw);

      for (final recordEntry in attendance.entries) {
        final recordValue = recordEntry.value;
        if (recordValue is! Map) continue;
        final record = recordValue.map((k, v) => MapEntry(k.toString(), v));

        final recordTeacherUid = (record['teacherUid'] ?? '').toString().trim();
        final taughtByTeacher = recordTeacherUid.isEmpty
            ? classMatch
            : recordTeacherUid == teacherId.trim();
        if (!taughtByTeacher) continue;

        final present = (record['present'] is Map)
            ? Map<dynamic, dynamic>.from(record['present'] as Map)
            : <dynamic, dynamic>{};
        final absent = (record['absent'] is Map)
            ? Map<dynamic, dynamic>.from(record['absent'] as Map)
            : <dynamic, dynamic>{};
        final allUids = <String>{
          ...present.keys.map((k) => k.toString().trim()),
          ...absent.keys.map((k) => k.toString().trim()),
        }..removeWhere((uid) => uid.isEmpty);

        for (final uid in allUids) {
          final key = _sessionKey(uid: uid, courseId: courseId);
          final current = out[key] ?? const _SessionCounts();
          out[key] = _SessionCounts(
            held: current.held + 1,
            present: current.present,
          );
        }

        for (final uid in present.keys.map((k) => k.toString().trim())) {
          if (uid.isEmpty) continue;
          final key = _sessionKey(uid: uid, courseId: courseId);
          final current = out[key] ?? const _SessionCounts();
          out[key] = _SessionCounts(
            held: current.held,
            present: current.present + 1,
          );
        }
      }
    }

    return out;
  }

  static String _statusLabelFromParts({
    required int readyGross,
    required int pendingGross,
    required int receivedGross,
  }) {
    if (readyGross > 0) return 'Ready';
    if (pendingGross > 0) return 'Pending';
    if (receivedGross > 0) return 'Received';
    return 'Pending';
  }

  Future<void> _confirmReceived({
    required BuildContext context,
    required _TeacherWageRowData row,
  }) async {
    if (row.readyPaymentIds.isEmpty) return;

    final ok =
        await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            backgroundColor: p.cardBg,
            title: Text(
              'Confirm received?',
              style: TextStyle(color: p.primary, fontWeight: FontWeight.w900),
            ),
            content: Text(
              'This will mark ready payments as received for ${row.learnerName}.',
              style: TextStyle(
                color: p.text.withValues(alpha: 0.82),
                fontWeight: FontWeight.w700,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text('Cancel', style: TextStyle(color: p.primary)),
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Colors.green),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Confirm'),
              ),
            ],
          ),
        ) ??
        false;

    if (!ok) return;

    try {
      for (final refKey in row.readyPaymentIds) {
        final parts = refKey.split('|');
        final paymentId = parts.isNotEmpty ? parts.first : '';
        final allocationId = parts.length > 1 ? parts[1] : '';
        if (paymentId.isEmpty) continue;
        if (allocationId.isEmpty) {
          await FirebaseDatabase.instance.ref('payments/$paymentId').update({
            'teacherConfirmed': true,
            'teacherConfirmedAt': ServerValue.timestamp,
            'teacherConfirmedBy': FirebaseAuth.instance.currentUser?.uid ?? '',
            'financePayoutStatus': 'done',
            'updatedAt': ServerValue.timestamp,
          });
          continue;
        }
        final allocationPath =
            'payments/$paymentId/financeAllocations/$allocationId';
        await FirebaseDatabase.instance.ref(allocationPath).update({
          'teacherConfirmed': true,
          'teacherConfirmedAt': ServerValue.timestamp,
          'teacherConfirmedBy': FirebaseAuth.instance.currentUser?.uid ?? '',
          'payoutStatus': 'done',
          'updatedAt': ServerValue.timestamp,
        });
      }

      if (!context.mounted) return;
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('Marked as received.')),
      );
    } catch (e) {
      if (!context.mounted) return;
      AppToast.fromSnackBar(
        context,
        SnackBar(
          content: Text(
            toHumanError(e, fallback: 'Could not confirm this payment.'),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final myUid = FirebaseAuth.instance.currentUser?.uid ?? '';

    return Scaffold(
      backgroundColor: p.appBg,
      appBar: AppBar(
        backgroundColor: p.cardBg,
        elevation: 0,
        surfaceTintColor: p.cardBg,
        iconTheme: IconThemeData(color: p.primary),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'My Payments',
              style: TextStyle(
                color: p.primary,
                fontWeight: FontWeight.w900,
                fontSize: 18,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              'Added by admin',
              style: TextStyle(
                color: p.text.withValues(alpha: 0.65),
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
      body: teacherWebBodyFrame(
        context: context,
        maxWidth: 1540,
        child: StreamBuilder<DatabaseEvent>(
          stream: myUid.isEmpty
              ? const Stream<DatabaseEvent>.empty()
              : FirebaseDatabase.instance.ref('payments').onValue,
          builder: (context, snap) {
            if (snap.hasError) {
              return Center(
                child: Text(
                  'Could not load wages.',
                  style: TextStyle(
                    color: p.primary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              );
            }

            if (!snap.hasData) {
              return Center(child: CircularProgressIndicator(color: p.accent));
            }

            return StreamBuilder<DatabaseEvent>(
              stream: myUid.isEmpty
                  ? const Stream<DatabaseEvent>.empty()
                  : FirebaseDatabase.instance.ref('classes').onValue,
              builder: (context, classesSnap) {
                if (classesSnap.hasError) {
                  return Center(
                    child: Text(
                      'Could not load classes.',
                      style: TextStyle(
                        color: p.primary,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  );
                }

                if (!classesSnap.hasData) {
                  return Center(
                    child: CircularProgressIndicator(color: p.accent),
                  );
                }

                final raw = snap.data?.snapshot.value;
                if (raw is! Map) {
                  return _EmptyWagesState(
                    palette: p,
                    text: 'No pushed wage items found.',
                  );
                }

                final classesRaw = classesSnap.data?.snapshot.value;
                final classMetaByCourse = _classMetaByCourse(classesRaw);
                final attendanceCounts = _attendanceCountsByLearnerCourse(
                  raw: classesRaw,
                  teacherId: myUid,
                );

                final grouped = <String, _TeacherWageRowAccumulator>{};
                raw.forEach((k, v) {
                  if (k == null || v == null || v is! Map) return;
                  final m = v.map((kk, vv) => MapEntry(kk.toString(), vv));
                  final payment = m.cast<String, dynamic>();
                  payment['paymentId'] = k.toString();
                  final allocations = financeAllocationsFromPayment(payment);
                  for (final allocation in allocations) {
                    if (allocation.teacherId.trim() != myUid) continue;
                    if (allocation.pushedAt <= 0) continue;

                    final learnerName = financeLearnerNameFrom(payment);
                    final learnerUid = _learnerUidFromPayment(payment);
                    final courseId = _courseIdFromPayment(payment);
                    final groupingKey = learnerUid.isNotEmpty
                        ? '$learnerUid|$courseId'
                        : '${learnerName.toLowerCase()}|$courseId';
                    final deliveryLabel = _deliveryLabelFromPayment(
                      payment,
                      fallback: classMetaByCourse[courseId],
                    );
                    final acc = grouped.putIfAbsent(
                      groupingKey,
                      () => _TeacherWageRowAccumulator(
                        learnerName: learnerName.isEmpty
                            ? '(No name)'
                            : learnerName,
                        learnerSerial: (payment['learner_serial'] ?? '')
                            .toString()
                            .trim(),
                        learnerUid: learnerUid,
                        courseId: courseId,
                        deliveryLabel: deliveryLabel,
                      ),
                    );

                    acc.paidAtMs =
                        TeacherWagesScreen.asInt(payment['paidAt']) >
                            acc.paidAtMs
                        ? TeacherWagesScreen.asInt(payment['paidAt'])
                        : acc.paidAtMs;
                    if (acc.learnerSerial.isEmpty) {
                      acc.learnerSerial = (payment['learner_serial'] ?? '')
                          .toString()
                          .trim();
                    }
                    if (acc.deliveryLabel.isEmpty) {
                      acc.deliveryLabel = deliveryLabel;
                    }
                    acc.netTotal += allocation.teacherNet;
                    acc.readyGross += allocation.payoutStatus == 'tbpaid'
                        ? allocation.grossShare
                        : 0;
                    acc.pendingGross += allocation.payoutStatus == 'waiting'
                        ? allocation.grossShare
                        : 0;
                    acc.receivedGross += allocation.payoutStatus == 'done'
                        ? allocation.grossShare
                        : 0;
                    acc.assignedSessions += allocation.assignedSessions ?? 0;
                    acc.allocationCount += 1;
                    acc.teacherPercentLabels.add(
                      '${allocation.teacherPercent}%',
                    );
                    if (allocation.payoutStatus == 'tbpaid') {
                      acc.readyPaymentIds.add(
                        allocation.isLegacy
                            ? allocation.paymentId
                            : '${allocation.paymentId}|${allocation.allocationId}',
                      );
                    }
                  }
                });

                final rows = grouped.values.map((acc) {
                  final sess =
                      (acc.learnerUid.isNotEmpty && acc.courseId.isNotEmpty)
                      ? (attendanceCounts[_sessionKey(
                              uid: acc.learnerUid,
                              courseId: acc.courseId,
                            )] ??
                            const _SessionCounts())
                      : const _SessionCounts();
                  final absentCount = sess.held - sess.present;
                  return _TeacherWageRowData(
                    learnerName: acc.learnerName,
                    learnerSerial: acc.learnerSerial,
                    paidAtMs: acc.paidAtMs,
                    percentLabel: acc.teacherPercentLabels.length == 1
                        ? acc.teacherPercentLabels.first
                        : 'Mixed',
                    deliveryLabel: acc.deliveryLabel.isEmpty
                        ? 'Class'
                        : acc.deliveryLabel,
                    assignedSessions: acc.assignedSessions,
                    sessionTotal: sess.held,
                    presentCount: sess.present,
                    absentCount: absentCount < 0 ? 0 : absentCount,
                    netTotal: acc.netTotal,
                    statusLabel: _statusLabelFromParts(
                      readyGross: acc.readyGross,
                      pendingGross: acc.pendingGross,
                      receivedGross: acc.receivedGross,
                    ),
                    readyPaymentIds: List<String>.from(acc.readyPaymentIds),
                  );
                }).toList();

                if (rows.isEmpty) {
                  return _EmptyWagesState(
                    palette: p,
                    text: 'No pushed items right now.',
                  );
                }

                rows.sort((a, b) => b.paidAtMs.compareTo(a.paidAtMs));
                var netTotal = 0;
                var readyCount = 0;
                var pendingCount = 0;
                var receivedCount = 0;
                for (final row in rows) {
                  netTotal += row.netTotal;
                  if (row.statusLabel == 'Ready') {
                    readyCount += 1;
                  } else if (row.statusLabel == 'Received') {
                    receivedCount += 1;
                  } else {
                    pendingCount += 1;
                  }
                }

                return ListView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _WageChip(
                          label: 'Net total',
                          value: _money(netTotal),
                          color: const Color(0xFF22945A),
                        ),
                        _WageChip(
                          label: 'Ready',
                          value: '$readyCount',
                          color: const Color(0xFF3666D8),
                        ),
                        _WageChip(
                          label: 'Pending',
                          value: '$pendingCount',
                          color: const Color(0xFFF0A526),
                        ),
                        _WageChip(
                          label: 'Received',
                          value: '$receivedCount',
                          color: const Color(0xFF22945A),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    ...rows.map((row) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _TeacherWageRow(
                          palette: p,
                          row: row,
                          onConfirm: row.readyPaymentIds.isNotEmpty
                              ? () =>
                                    _confirmReceived(context: context, row: row)
                              : null,
                        ),
                      );
                    }),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _TeacherWageRowData {
  const _TeacherWageRowData({
    required this.learnerName,
    required this.learnerSerial,
    required this.paidAtMs,
    required this.percentLabel,
    required this.deliveryLabel,
    required this.assignedSessions,
    required this.sessionTotal,
    required this.presentCount,
    required this.absentCount,
    required this.netTotal,
    required this.statusLabel,
    required this.readyPaymentIds,
  });

  final String learnerName;
  final String learnerSerial;
  final int paidAtMs;
  final String percentLabel;
  final String deliveryLabel;
  final int assignedSessions;
  final int sessionTotal;
  final int presentCount;
  final int absentCount;
  final int netTotal;
  final String statusLabel;
  final List<String> readyPaymentIds;
}

class _TeacherWageRow extends StatelessWidget {
  const _TeacherWageRow({
    required this.palette,
    required this.row,
    this.onConfirm,
  });

  final AppPalette palette;
  final _TeacherWageRowData row;
  final VoidCallback? onConfirm;

  @override
  Widget build(BuildContext context) {
    final paidAt = TeacherWagesScreen.fmtYmdFromMs(row.paidAtMs);
    final statusColor = row.statusLabel == 'Ready'
        ? const Color(0xFF3666D8)
        : row.statusLabel == 'Received'
        ? const Color(0xFF22945A)
        : const Color(0xFFF0A526);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF3666D8).withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: const Color(0xFF3666D8).withValues(alpha: 0.38),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      row.learnerName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        color: palette.text,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      [
                        if (paidAt.isNotEmpty) paidAt,
                        row.deliveryLabel,
                      ].join(' • '),
                      style: TextStyle(
                        color: palette.text.withValues(alpha: 0.72),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (row.learnerSerial.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        'Serial: ${row.learnerSerial}',
                        style: TextStyle(
                          color: palette.text.withValues(alpha: 0.66),
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${row.netTotal} DA',
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      color: palette.text,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: statusColor.withValues(alpha: 0.35),
                      ),
                    ),
                    child: Text(
                      row.statusLabel,
                      style: TextStyle(
                        color: statusColor,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          if (row.sessionTotal > 0) ...[
            const SizedBox(height: 8),
            Text(
              'Sessions: ${row.presentCount}/${row.sessionTotal} present',
              style: TextStyle(
                color: palette.text.withValues(alpha: 0.78),
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
          if (onConfirm != null) ...[
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: onConfirm,
              icon: const Icon(Icons.verified_rounded),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.green,
                foregroundColor: Colors.white,
              ),
              label: const Text('Mark as received'),
            ),
          ],
        ],
      ),
    );
  }
}

class _WageChip extends StatelessWidget {
  const _WageChip({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Text(
        '$label: $value',
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w900,
          fontSize: 12,
        ),
      ),
    );
  }
}

class _EmptyWagesState extends StatelessWidget {
  const _EmptyWagesState({required this.palette, required this.text});

  final AppPalette palette;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          color: palette.cardBg,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: palette.border.withValues(alpha: 0.86)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 58,
              height: 58,
              decoration: BoxDecoration(
                color: palette.soft,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.payments_outlined,
                color: palette.primary,
                size: 30,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontWeight: FontWeight.w900,
                color: palette.primary,
                fontSize: 16,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TeacherClassMeta {
  const _TeacherClassMeta({required this.variantKey, required this.studyMode});

  final String variantKey;
  final String studyMode;
}

class _SessionCounts {
  const _SessionCounts({this.held = 0, this.present = 0});

  final int held;
  final int present;
}

class _TeacherWageRowAccumulator {
  _TeacherWageRowAccumulator({
    required this.learnerName,
    required this.learnerSerial,
    required this.learnerUid,
    required this.courseId,
    required this.deliveryLabel,
  });

  final String learnerName;
  String learnerSerial;
  final String learnerUid;
  final String courseId;
  String deliveryLabel;
  int paidAtMs = 0;
  int netTotal = 0;
  int assignedSessions = 0;
  int readyGross = 0;
  int pendingGross = 0;
  int receivedGross = 0;
  int allocationCount = 0;
  final Set<String> teacherPercentLabels = <String>{};
  final List<String> readyPaymentIds = <String>[];
}
