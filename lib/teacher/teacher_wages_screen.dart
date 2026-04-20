import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../shared/app_feedback.dart';
import '../shared/app_theme.dart';
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

  static String _normalizeStatus(dynamic v) {
    final s = (v ?? '').toString().trim().toLowerCase();
    if (s == 'done' || s == 'tbpaid' || s == 'split' || s == 'waiting') {
      return s;
    }
    return 'tbpaid';
  }

  static _TeacherAllocation _allocationFromPayment(
    Map<String, dynamic> payment,
  ) {
    final original = TeacherWagesScreen.asInt(payment['amount']);
    final status = _normalizeStatus(payment['financePayoutStatus']);

    if (status == 'done') {
      return _TeacherAllocation(
        original: original,
        tbpaid: 0,
        waiting: 0,
        done: original,
        paidStatusForSplit: null,
      );
    }
    if (status == 'waiting') {
      return _TeacherAllocation(
        original: original,
        tbpaid: 0,
        waiting: original,
        done: 0,
        paidStatusForSplit: null,
      );
    }
    if (status == 'tbpaid') {
      return _TeacherAllocation(
        original: original,
        tbpaid: original,
        waiting: 0,
        done: 0,
        paidStatusForSplit: null,
      );
    }

    final splitPaid = TeacherWagesScreen.asInt(
      payment['financeSplitPaidAmount'],
    );
    var splitWaiting = TeacherWagesScreen.asInt(
      payment['financeSplitWaitingAmount'],
    );
    if (splitWaiting <= 0) splitWaiting = original - splitPaid;
    final paid = splitPaid.clamp(0, original);
    final waiting = splitWaiting.clamp(0, original - paid);
    final paidStatus =
        _normalizeStatus(payment['financeSplitPaidStatus']) == 'done'
        ? 'done'
        : 'tbpaid';

    return _TeacherAllocation(
      original: original,
      tbpaid: paidStatus == 'tbpaid' ? paid : 0,
      waiting: waiting,
      done: paidStatus == 'done' ? paid : 0,
      paidStatusForSplit: paidStatus,
    );
  }

  static int _teacherPercent(dynamic v) {
    final p = TeacherWagesScreen.asInt(v);
    if (p <= 0) return 100;
    if (p > 100) return 100;
    return p;
  }

  static int _netOf(int amount, int percent) {
    if (amount <= 0) return 0;
    return ((amount * percent) / 100).round();
  }

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
      for (final paymentId in row.readyPaymentIds) {
        final ref = FirebaseDatabase.instance.ref('payments/$paymentId');
        final snap = await ref.get();
        final v = snap.value;
        if (v is! Map) continue;

        final m = v.map((k, vv) => MapEntry(k.toString(), vv));
        final status = _normalizeStatus(m['financePayoutStatus']);

        final updates = <String, dynamic>{
          'teacherConfirmed': true,
          'teacherConfirmedAt': ServerValue.timestamp,
          'teacherConfirmedBy': FirebaseAuth.instance.currentUser?.uid ?? '',
        };

        if (status == 'tbpaid') {
          updates['financePayoutStatus'] = 'done';
        } else if (status == 'split') {
          updates['financeSplitPaidStatus'] = 'done';
        }

        await ref.update(updates);
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
              : FirebaseDatabase.instance
                    .ref('payments')
                    .orderByChild('teacherId')
                    .equalTo(myUid)
                    .onValue,
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

                  final pushedAt = TeacherWagesScreen.asInt(
                    m['financePushedAt'],
                  );
                  if (pushedAt <= 0) return;

                  final payment = m.cast<String, dynamic>();
                  final alloc = _allocationFromPayment(payment);
                  final percent = _teacherPercent(
                    payment['financeTeacherPercent'],
                  );
                  final learnerName =
                      (payment['learner_name'] ??
                              payment['learnerName'] ??
                              '(No name)')
                          .toString()
                          .trim();
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
                      teacherPercent: percent,
                    ),
                  );

                  acc.paidAtMs =
                      TeacherWagesScreen.asInt(payment['paidAt']) > acc.paidAtMs
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
                  acc.teacherPercent = percent;
                  acc.netTotal +=
                      _netOf(alloc.tbpaid, percent) +
                      _netOf(alloc.waiting, percent) +
                      _netOf(alloc.done, percent);
                  acc.readyGross += alloc.tbpaid;
                  acc.pendingGross += alloc.waiting;
                  acc.receivedGross += alloc.done;
                  if (alloc.tbpaid > 0) {
                    acc.readyPaymentIds.add(k.toString());
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
                    teacherPercent: acc.teacherPercent,
                    deliveryLabel: acc.deliveryLabel.isEmpty
                        ? 'Class'
                        : acc.deliveryLabel,
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
                for (final row in rows) {
                  netTotal += row.netTotal;
                }

                return ListView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
                  children: [
                    Text(
                      'Net = ${_money(netTotal)}',
                      style: TextStyle(
                        color: p.primary,
                        fontWeight: FontWeight.w900,
                        fontSize: 22,
                      ),
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

class _TeacherAllocation {
  const _TeacherAllocation({
    required this.original,
    required this.tbpaid,
    required this.waiting,
    required this.done,
    required this.paidStatusForSplit,
  });

  final int original;
  final int tbpaid;
  final int waiting;
  final int done;
  final String? paidStatusForSplit;
}

class _TeacherWageRowData {
  const _TeacherWageRowData({
    required this.learnerName,
    required this.learnerSerial,
    required this.paidAtMs,
    required this.teacherPercent,
    required this.deliveryLabel,
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
  final int teacherPercent;
  final String deliveryLabel;
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
            children: [
              Expanded(
                child: Text(
                  row.learnerName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: palette.text,
                    fontSize: 14,
                  ),
                ),
              ),
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
          const SizedBox(height: 5),
          Text(
            [
              if (row.learnerSerial.isNotEmpty) row.learnerSerial,
              if (paidAt.isNotEmpty) paidAt,
              row.deliveryLabel,
            ].join(' • '),
            style: TextStyle(
              color: palette.text.withValues(alpha: 0.72),
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Sessions: ${row.sessionTotal} • Present: ${row.presentCount} • Absent: ${row.absentCount}',
            style: TextStyle(
              color: palette.text.withValues(alpha: 0.84),
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _WageChip(
                label: 'My share',
                value: '${row.teacherPercent}%',
                color: const Color(0xFF3666D8),
              ),
              _WageChip(
                label: 'Net',
                value: '${row.netTotal} DA',
                color: const Color(0xFF22945A),
              ),
            ],
          ),
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
    required this.teacherPercent,
  });

  final String learnerName;
  String learnerSerial;
  final String learnerUid;
  final String courseId;
  String deliveryLabel;
  int teacherPercent;
  int paidAtMs = 0;
  int netTotal = 0;
  int readyGross = 0;
  int pendingGross = 0;
  int receivedGross = 0;
  final List<String> readyPaymentIds = <String>[];
}
