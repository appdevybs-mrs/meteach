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

  static String financePeriodLabel({
    required String startDate,
    required String endDate,
  }) {
    final start = startDate.trim();
    final end = endDate.trim();
    if (start.isEmpty) return 'No finance cycle';
    return end.isEmpty ? 'From $start To ...' : 'From $start To $end';
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

  final DatabaseReference _financePayoutPeriodsRef = FirebaseDatabase.instance
      .ref('finance_payout_periods');

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
      final courseCode = (cls['course_code'] ?? '').toString().trim();
      final courseTitle = (cls['course_title'] ?? cls['title'] ?? '')
          .toString()
          .trim();
      var firstSessionDate = '';
      final schedule = cls['schedule'];
      if (schedule is Map) {
        firstSessionDate = (schedule['first_session_date'] ?? '')
            .toString()
            .trim();
      }

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
        courseCode: courseCode,
        courseTitle: courseTitle,
        firstSessionDate: firstSessionDate,
      );
    }

    return out;
  }

  static String _courseLabelFromPayment(
    Map<String, dynamic> payment, {
    _TeacherClassMeta? fallback,
  }) {
    final code = (payment['course_code'] ?? fallback?.courseCode ?? '')
        .toString()
        .trim();
    final title =
        (payment['course_title'] ??
                payment['courseTitle'] ??
                fallback?.courseTitle ??
                '')
            .toString()
            .trim();
    if (code.isNotEmpty && title.isNotEmpty) return '$code - $title';
    if (title.isNotEmpty) return title;
    if (code.isNotEmpty) return code;
    return 'Course';
  }

  static Map<String, int> _monthIndexByPaymentId(dynamic raw) {
    final out = <String, int>{};
    final grouped = <String, List<Map<String, dynamic>>>{};
    if (raw is! Map) return out;
    final items = Map<dynamic, dynamic>.from(raw);
    for (final e in items.entries) {
      final paymentId = e.key.toString().trim();
      if (paymentId.isEmpty) continue;
      final v = e.value;
      if (v is! Map) continue;
      final m = v.map((k, val) => MapEntry(k.toString(), val));
      final uid = _learnerUidFromPayment(m.cast<String, dynamic>());
      final courseId = _courseIdFromPayment(m.cast<String, dynamic>());
      if (uid.isEmpty || courseId.isEmpty) continue;
      final key = _sessionKey(uid: uid, courseId: courseId);
      grouped.putIfAbsent(key, () => <Map<String, dynamic>>[]).add({
        'paymentId': paymentId,
        'paidAt': TeacherWagesScreen.asInt(m['paidAt']),
      });
    }

    for (final bucket in grouped.values) {
      bucket.sort((a, b) {
        final byDate = TeacherWagesScreen.asInt(
          a['paidAt'],
        ).compareTo(TeacherWagesScreen.asInt(b['paidAt']));
        if (byDate != 0) return byDate;
        return (a['paymentId'] ?? '').toString().compareTo(
          (b['paymentId'] ?? '').toString(),
        );
      });
      for (var i = 0; i < bucket.length; i++) {
        final pid = (bucket[i]['paymentId'] ?? '').toString().trim();
        if (pid.isEmpty) continue;
        out[pid] = i + 1;
      }
    }
    return out;
  }

  static Map<String, int> _monthOverrideByPaymentId(dynamic raw) {
    final out = <String, int>{};
    if (raw is! Map) return out;
    final items = Map<dynamic, dynamic>.from(raw);
    for (final e in items.entries) {
      final paymentId = e.key.toString().trim();
      if (paymentId.isEmpty) continue;
      final v = e.value;
      if (v is! Map) continue;
      final m = Map<dynamic, dynamic>.from(v);
      final monthOverride = TeacherWagesScreen.asInt(m['monthOverride']);
      if (monthOverride > 0) out[paymentId] = monthOverride;
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
    if (!context.mounted) return;

    await _confirmPaymentRefs(
      context: context,
      paymentRefs: row.readyPaymentIds,
      fallbackError: 'Could not confirm this payment.',
    );
  }

  Future<void> _confirmPaymentRefs({
    required BuildContext context,
    required List<String> paymentRefs,
    required String fallbackError,
  }) async {
    if (paymentRefs.isEmpty) return;

    try {
      for (final refKey in paymentRefs) {
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
        SnackBar(content: Text(toHumanError(e, fallback: fallbackError))),
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
          stream: _financePayoutPeriodsRef.onValue,
          builder: (context, periodsSnap) {
            if (periodsSnap.hasError) {
              return Center(
                child: Text(
                  'Could not load finance cycle.',
                  style: TextStyle(
                    color: p.primary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              );
            }

            final periodsRaw = periodsSnap.data?.snapshot.value;
            final periods = <_TeacherFinancePayoutPeriod>[];
            if (periodsRaw is Map) {
              periodsRaw.forEach((k, v) {
                if (v is! Map) return;
                final map = v.map((kk, vv) => MapEntry(kk.toString(), vv));
                periods.add(
                  _TeacherFinancePayoutPeriod.fromMap(
                    id: k.toString(),
                    map: map.cast<String, dynamic>(),
                  ),
                );
              });
            }
            periods.sort((a, b) => b.startAtMs.compareTo(a.startAtMs));
            _TeacherFinancePayoutPeriod? activePeriod;
            for (final period in periods) {
              if (period.isActive) {
                activePeriod = period;
                break;
              }
            }

            if (activePeriod == null) {
              return _EmptyWagesState(
                palette: p,
                text: 'No active finance cycle yet.',
              );
            }
            final currentFinancePeriod = activePeriod;

            return StreamBuilder<DatabaseEvent>(
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
                final monthByPaymentId = _monthIndexByPaymentId(raw);
                return StreamBuilder<DatabaseEvent>(
                  stream: myUid.isEmpty
                      ? const Stream<DatabaseEvent>.empty()
                      : FirebaseDatabase.instance
                            .ref('finance_payment_meta')
                            .onValue,
                  builder: (context, financeMetaSnap) {
                    final monthOverrides = _monthOverrideByPaymentId(
                      financeMetaSnap.data?.snapshot.value,
                    );
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

                        final classesRaw = classesSnap.data?.snapshot.value;
                        final classMetaByCourse = _classMetaByCourse(
                          classesRaw,
                        );
                        final attendanceCounts =
                            _attendanceCountsByLearnerCourse(
                              raw: classesRaw,
                              teacherId: myUid,
                            );

                        final grouped = <String, _TeacherWageRowAccumulator>{};
                        raw.forEach((k, v) {
                          if (k == null || v == null || v is! Map) return;
                          final m = v.map(
                            (kk, vv) => MapEntry(kk.toString(), vv),
                          );
                          final payment = m.cast<String, dynamic>();
                          payment['paymentId'] = k.toString();
                          if ((payment['financePeriodId'] ?? '')
                                  .toString()
                                  .trim() !=
                              currentFinancePeriod.id) {
                            return;
                          }
                          final allocations = financeAllocationsFromPayment(
                            payment,
                          );
                          for (final allocation in allocations) {
                            if (allocation.teacherId.trim() != myUid) continue;
                            if (allocation.pushedAt <= 0) continue;

                            final learnerName = financeLearnerNameFrom(payment);
                            final learnerUid = _learnerUidFromPayment(payment);
                            final courseId = _courseIdFromPayment(payment);
                            final classMeta = classMetaByCourse[courseId];
                            final courseLabel = _courseLabelFromPayment(
                              payment,
                              fallback: classMeta,
                            );
                            final groupingKey = learnerUid.isNotEmpty
                                ? '$learnerUid|$courseId'
                                : '${learnerName.toLowerCase()}|$courseId';
                            final paymentId = (payment['paymentId'] ?? '')
                                .toString()
                                .trim();
                            final monthComputed =
                                monthByPaymentId[paymentId] ?? 0;
                            final monthOverride =
                                monthOverrides[paymentId] ?? 0;
                            final monthNumber = monthOverride > 0
                                ? monthOverride
                                : monthComputed;
                            final classFirstSession =
                                (classMeta?.firstSessionDate ?? '').trim();
                            final paymentStartDate =
                                (payment['startDate'] ?? '').toString().trim();
                            final paymentDate = TeacherWagesScreen.fmtYmdFromMs(
                              TeacherWagesScreen.asInt(payment['paidAt']),
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
                                courseLabel: courseLabel,
                                firstSessionDate: classFirstSession.isNotEmpty
                                    ? classFirstSession
                                    : (paymentStartDate.isNotEmpty
                                          ? paymentStartDate
                                          : paymentDate),
                                firstSessionFallback: classFirstSession.isEmpty,
                                monthNumber: monthNumber,
                              ),
                            );

                            final paidAtMs = TeacherWagesScreen.asInt(
                              payment['paidAt'],
                            );
                            if (paidAtMs > acc.paidAtMs) {
                              acc.paidAtMs = paidAtMs;
                              acc.monthNumber = monthNumber;
                            } else if (acc.monthNumber <= 0 &&
                                monthNumber > 0) {
                              acc.monthNumber = monthNumber;
                            }
                            if (acc.learnerSerial.isEmpty) {
                              acc.learnerSerial =
                                  (payment['learner_serial'] ?? '')
                                      .toString()
                                      .trim();
                            }
                            if (acc.courseLabel.isEmpty) {
                              acc.courseLabel = courseLabel;
                            }
                            if (!acc.firstSessionFallback &&
                                acc.firstSessionDate.isNotEmpty) {
                              // Keep class-derived first session when already present.
                            } else if (classFirstSession.isNotEmpty) {
                              acc.firstSessionDate = classFirstSession;
                              acc.firstSessionFallback = false;
                            } else if (acc.firstSessionDate.isEmpty) {
                              if (paymentStartDate.isNotEmpty) {
                                acc.firstSessionDate = paymentStartDate;
                                acc.firstSessionFallback = true;
                              } else if (paymentDate.isNotEmpty) {
                                acc.firstSessionDate = paymentDate;
                                acc.firstSessionFallback = true;
                              }
                            }
                            acc.netTotal += allocation.teacherNet;
                            acc.readyGross +=
                                allocation.payoutStatus == 'tbpaid'
                                ? allocation.grossShare
                                : 0;
                            acc.pendingGross +=
                                allocation.payoutStatus == 'waiting'
                                ? allocation.grossShare
                                : 0;
                            acc.receivedGross +=
                                allocation.payoutStatus == 'done'
                                ? allocation.grossShare
                                : 0;
                            acc.assignedSessions +=
                                allocation.assignedSessions ?? 0;
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
                              (acc.learnerUid.isNotEmpty &&
                                  acc.courseId.isNotEmpty)
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
                            courseLabel: acc.courseLabel,
                            firstSessionDate: acc.firstSessionDate,
                            firstSessionFallback: acc.firstSessionFallback,
                            monthNumber: acc.monthNumber,
                            paidAtMs: acc.paidAtMs,
                            percentLabel: acc.teacherPercentLabels.length == 1
                                ? acc.teacherPercentLabels.first
                                : 'Mixed',
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
                            readyPaymentIds: List<String>.from(
                              acc.readyPaymentIds,
                            ),
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
                        final allReadyRefs = <String>{};
                        for (final row in rows) {
                          netTotal += row.netTotal;
                          allReadyRefs.addAll(row.readyPaymentIds);
                        }

                        return ListView(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
                          children: [
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                _WageChip(
                                  label: 'Total',
                                  value: _money(netTotal),
                                  color: const Color(0xFF22945A),
                                ),
                                FilledButton.icon(
                                  onPressed: allReadyRefs.isEmpty
                                      ? null
                                      : () async {
                                          final ok =
                                              await showDialog<bool>(
                                                context: context,
                                                builder: (_) => AlertDialog(
                                                  backgroundColor: p.cardBg,
                                                  title: Text(
                                                    'Confirm received?',
                                                    style: TextStyle(
                                                      color: p.primary,
                                                      fontWeight:
                                                          FontWeight.w900,
                                                    ),
                                                  ),
                                                  content: Text(
                                                    'This will mark all ready payments as received.',
                                                    style: TextStyle(
                                                      color: p.text.withValues(
                                                        alpha: 0.82,
                                                      ),
                                                      fontWeight:
                                                          FontWeight.w700,
                                                    ),
                                                  ),
                                                  actions: [
                                                    TextButton(
                                                      onPressed: () =>
                                                          Navigator.pop(
                                                            context,
                                                            false,
                                                          ),
                                                      child: Text(
                                                        'Cancel',
                                                        style: TextStyle(
                                                          color: p.primary,
                                                        ),
                                                      ),
                                                    ),
                                                    FilledButton(
                                                      style:
                                                          FilledButton.styleFrom(
                                                            backgroundColor:
                                                                Colors.green,
                                                          ),
                                                      onPressed: () =>
                                                          Navigator.pop(
                                                            context,
                                                            true,
                                                          ),
                                                      child: const Text(
                                                        'Confirm',
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ) ??
                                              false;
                                          if (!ok) return;
                                          if (!context.mounted) return;
                                          await _confirmPaymentRefs(
                                            context: context,
                                            paymentRefs: allReadyRefs.toList(),
                                            fallbackError:
                                                'Could not confirm payments.',
                                          );
                                        },
                                  icon: const Icon(Icons.verified_rounded),
                                  style: FilledButton.styleFrom(
                                    backgroundColor: Colors.green,
                                    foregroundColor: Colors.white,
                                  ),
                                  label: const Text('Confirm Received'),
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
                                      ? () => _confirmReceived(
                                          context: context,
                                          row: row,
                                        )
                                      : null,
                                ),
                              );
                            }),
                          ],
                        );
                      },
                    );
                  },
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _TeacherFinancePayoutPeriod {
  const _TeacherFinancePayoutPeriod({
    required this.id,
    required this.startDate,
    required this.startAtMs,
    required this.endDate,
    required this.endAtMs,
    required this.isActive,
  });

  final String id;
  final String startDate;
  final int startAtMs;
  final String endDate;
  final int endAtMs;
  final bool isActive;

  factory _TeacherFinancePayoutPeriod.fromMap({
    required String id,
    required Map<String, dynamic> map,
  }) {
    return _TeacherFinancePayoutPeriod(
      id: id,
      startDate: (map['startDate'] ?? '').toString().trim(),
      startAtMs: TeacherWagesScreen.asInt(map['startAtMs']),
      endDate: (map['endDate'] ?? '').toString().trim(),
      endAtMs: TeacherWagesScreen.asInt(map['endAtMs']),
      isActive: map['isActive'] == true,
    );
  }

  String get displayLabel => TeacherWagesScreen.financePeriodLabel(
    startDate: startDate,
    endDate: endDate,
  );
}

class _TeacherWageRowData {
  const _TeacherWageRowData({
    required this.learnerName,
    required this.learnerSerial,
    required this.courseLabel,
    required this.firstSessionDate,
    required this.firstSessionFallback,
    required this.monthNumber,
    required this.paidAtMs,
    required this.percentLabel,
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
  final String courseLabel;
  final String firstSessionDate;
  final bool firstSessionFallback;
  final int monthNumber;
  final int paidAtMs;
  final String percentLabel;
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
    final monthLabel = 'M${row.monthNumber > 0 ? row.monthNumber : '-'}';

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
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        _WageChip(
                          label: 'Month',
                          value: monthLabel,
                          color: const Color(0xFF4B67D1),
                        ),
                        _WageChip(
                          label: 'Share',
                          value: row.percentLabel,
                          color: const Color(0xFF3666D8),
                        ),
                        _WageChip(
                          label: 'Amount',
                          value: '${row.netTotal} DA',
                          color: const Color(0xFF22945A),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (onConfirm != null)
                FilledButton.icon(
                  onPressed: onConfirm,
                  icon: const Icon(Icons.verified_rounded),
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                  ),
                  label: const Text('Received'),
                ),
            ],
          ),
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
  const _TeacherClassMeta({
    required this.variantKey,
    required this.studyMode,
    required this.courseCode,
    required this.courseTitle,
    required this.firstSessionDate,
  });

  final String variantKey;
  final String studyMode;
  final String courseCode;
  final String courseTitle;
  final String firstSessionDate;
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
    required this.courseLabel,
    required this.firstSessionDate,
    required this.firstSessionFallback,
    required this.monthNumber,
  });

  final String learnerName;
  String learnerSerial;
  final String learnerUid;
  final String courseId;
  String courseLabel;
  String firstSessionDate;
  bool firstSessionFallback;
  int monthNumber;
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
