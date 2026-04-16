import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'admin_wages_export_excel.dart';
import '../shared/admin_web_layout.dart';
import '../shared/human_error.dart';
import '../shared/app_feedback.dart';

class AdminWagesScreen extends StatelessWidget {
  const AdminWagesScreen({super.key});
  static const int _paymentsWindowSize = 3000;

  static const primaryBlue = Color(0xFF1A2B48);
  static const uiBorder = Color(0xFFD1D9E0);
  static const actionOrange = Color(0xFFF98D28);
  static const mainText = Color(0xFF2D2D2D);
  static const appBg = Color(0xFFF4F7F9);

  static int _asInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString()) ?? 0;
  }

  static bool _asBool(dynamic v) {
    if (v == null) return false;
    if (v is bool) return v;
    final s = v.toString().trim().toLowerCase();
    return s == 'true' || s == '1' || s == 'yes';
  }

  static String _normalizeFinanceStatus(dynamic v) {
    final s = (v ?? '').toString().trim().toLowerCase();
    if (s == 'done' || s == 'tbpaid' || s == 'split' || s == 'waiting') {
      return s;
    }
    return 'tbpaid';
  }

  static _FinanceAlloc _financeAlloc(Map<String, dynamic> p) {
    final amount = _asInt(p['amount']);
    final status = _normalizeFinanceStatus(p['financePayoutStatus']);
    if (status == 'done') {
      return _FinanceAlloc(gross: amount, tbpaid: 0, waiting: 0, done: amount);
    }
    if (status == 'waiting') {
      return _FinanceAlloc(gross: amount, tbpaid: 0, waiting: amount, done: 0);
    }
    if (status == 'tbpaid') {
      return _FinanceAlloc(gross: amount, tbpaid: amount, waiting: 0, done: 0);
    }

    final splitPaid = _asInt(p['financeSplitPaidAmount']);
    var splitWaiting = _asInt(p['financeSplitWaitingAmount']);
    if (splitWaiting <= 0) {
      splitWaiting = amount - splitPaid;
    }
    final paid = splitPaid.clamp(0, amount);
    final waiting = splitWaiting.clamp(0, amount - paid);
    final paidStatus =
        _normalizeFinanceStatus(p['financeSplitPaidStatus']) == 'done'
        ? 'done'
        : 'tbpaid';
    return _FinanceAlloc(
      gross: amount,
      tbpaid: paidStatus == 'tbpaid' ? paid : 0,
      waiting: waiting,
      done: paidStatus == 'done' ? paid : 0,
    );
  }

  static int _teacherPercent(dynamic v) {
    final p = _asInt(v);
    if (p <= 0) return 100;
    if (p > 100) return 100;
    return p;
  }

  static int _netOf(int amount, int percent) {
    if (amount <= 0) return 0;
    return ((amount * percent) / 100).round();
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _monthKeyFromPaidAtMs(int ms) {
    if (ms <= 0) return 'Unknown';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.year}-${_two(d.month)}'; // yyyy-MM
  }

  static String _monthKeyNow() {
    final d = DateTime.now();
    return '${d.year}-${_two(d.month)}'; // yyyy-MM
  }

  static String _prettyMonthLabel(String monthKey) {
    final parts = monthKey.split('-');
    if (parts.length != 2) return monthKey;
    final y = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (y == null || m == null) return monthKey;

    const names = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    final name = (m >= 1 && m <= 12) ? names[m - 1] : parts[1];
    return '$name $y';
  }

  static Map<String, _LearnerInfo> _parseLearners(dynamic raw) {
    // Expected common RTDB structure: users/<uid> => { learner_name/name, learner_serial/serial, ... }
    final out = <String, _LearnerInfo>{};
    if (raw is! Map) return out;

    raw.forEach((k, v) {
      final uid = (k ?? '').toString().trim();
      if (uid.isEmpty || v is! Map) return;

      final m = v.map((kk, vv) => MapEntry(kk.toString(), vv));

      final serial = (m['learner_serial'] ?? m['serial'] ?? m['code'] ?? '')
          .toString()
          .trim();

      final phone1 = (m['phone1'] ?? m['phone'] ?? '').toString().trim();
      final phone2 = (m['phone2'] ?? '').toString().trim();
      final email = (m['email'] ?? '').toString().trim();

      final first = (m['first_name'] ?? m['firstName'] ?? '').toString().trim();
      final last = (m['last_name'] ?? m['lastName'] ?? '').toString().trim();

      String name =
          (m['learner_name'] ??
                  m['name'] ??
                  m['fullName'] ??
                  m['displayName'] ??
                  '')
              .toString()
              .trim();

      // build from first + last if needed
      if (name.isEmpty) {
        name = [first, last].where((x) => x.isNotEmpty).join(' ').trim();
      }

      // Human-friendly fallback if still empty
      if (name.isEmpty) {
        if (serial.isNotEmpty) {
          name = serial;
        } else if (phone1.isNotEmpty) {
          name = phone1;
        } else if (phone2.isNotEmpty) {
          name = phone2;
        } else if (email.isNotEmpty) {
          name = email;
        } else {
          final u = uid;
          name = u.length > 6 ? 'ID …${u.substring(u.length - 6)}' : 'ID $u';
        }
      }

      out[uid] = _LearnerInfo(uid: uid, name: name, serial: serial);
    });

    return out;
  }

  static Map<String, Set<String>> _parseStudyingFromClasses(dynamic raw) {
    // Returns: teacherKey -> set(uid)
    // teacherKey prefers: class.teacherId OR instructor_current(...) OR instructor name
    final out = <String, Set<String>>{};
    if (raw is! Map) return out;

    raw.forEach((ck, cv) {
      if (cv is! Map) return;
      final c = cv.map((kk, vv) => MapEntry(kk.toString(), vv));

      final status = (c['status'] ?? '').toString().trim().toLowerCase();
      final isOpen = _asBool(c['is_open']);
      final active = status == 'active' && isOpen;
      if (!active) return;

      String teacherKey = '';
      final t1 = (c['teacherId'] ?? '').toString().trim();
      if (t1.isNotEmpty) {
        teacherKey = t1;
      } else {
        final ic = c['instructor_current'];
        if (ic is String && ic.trim().isNotEmpty) {
          teacherKey = ic.trim();
        } else if (ic is Map) {
          final icm = ic.map((kk, vv) => MapEntry(kk.toString(), vv));
          final tid = (icm['teacherId'] ?? icm['uid'] ?? icm['id'] ?? '')
              .toString()
              .trim();
          if (tid.isNotEmpty) teacherKey = tid;
        }
        if (teacherKey.isEmpty) {
          final name = (c['instructor'] ?? '').toString().trim();
          if (name.isNotEmpty) teacherKey = name;
        }
      }
      if (teacherKey.isEmpty) return;

      final learners = c['learners'];
      final uids = <String>[];

      if (learners is Map) {
        for (final k in learners.keys) {
          final uid = k.toString().trim();
          if (uid.isNotEmpty) uids.add(uid);
        }
      } else if (learners is List) {
        for (final it in learners) {
          final uid = it.toString().trim();
          if (uid.isNotEmpty) uids.add(uid);
        }
      }

      if (uids.isEmpty) return;

      out.putIfAbsent(teacherKey, () => <String>{});
      out[teacherKey]!.addAll(uids);
    });

    return out;
  }

  static Set<String>? _tryMatchStudyingByTeacherName({
    required String teacherName,
    required Map<String, Set<String>> studyingByTeacher,
  }) {
    final name = teacherName.trim();
    if (name.isEmpty) return null;

    if (studyingByTeacher.containsKey(name)) return studyingByTeacher[name];

    for (final entry in studyingByTeacher.entries) {
      if (entry.key.toLowerCase().trim() == name.toLowerCase().trim()) {
        return entry.value;
      }
    }
    return null;
  }

  static void _showMissingBottomSheet({
    required BuildContext context,
    required String title,
    required List<_LearnerInfo> learners,
  }) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (_) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 15,
                          color: primaryBlue,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (learners.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    child: Text(
                      'Nothing to show 🎉',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        color: Colors.black.withValues(alpha: 0.65),
                      ),
                    ),
                  )
                else
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: learners.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final l = learners[i];
                        final displayName = l.name.isNotEmpty
                            ? l.name
                            : '(No name)';
                        final sub = [
                          if (l.serial.isNotEmpty) l.serial,
                          l.uid,
                        ].join(' • ');

                        return ListTile(
                          dense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 4,
                          ),
                          title: Text(
                            displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w900),
                          ),
                          subtitle: Text(
                            sub,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _togglePaid({
    required BuildContext context,
    required String paymentId,
    required bool makePaid,
  }) async {
    final db = FirebaseDatabase.instance;
    final ref = db.ref('payments/$paymentId');

    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';

    final ok =
        await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: Text(makePaid ? 'Mark as PAID?' : 'Mark as UNPAID?'),
            content: Text(
              makePaid
                  ? 'This means you already gave the money to the teacher for this payment.'
                  : 'This will mark it as not paid to the teacher yet.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: makePaid ? Colors.green : Colors.red,
                ),
                onPressed: () => Navigator.pop(context, true),
                child: Text(makePaid ? 'Mark PAID' : 'Mark UNPAID'),
              ),
            ],
          ),
        ) ??
        false;

    if (!ok) return;

    try {
      if (makePaid) {
        await ref.update({
          'teacherPaid': true,
          'teacherPaidAt': ServerValue.timestamp,
          'teacherPaidBy': uid,
          'updatedAt': ServerValue.timestamp,
        });
      } else {
        await ref.update({
          'teacherPaid': false,
          'teacherPaidAt': null,
          'teacherPaidBy': null,
          'updatedAt': ServerValue.timestamp,
        });
      }

      if (!context.mounted) return;
      AppToast.fromSnackBar(
        context,
        SnackBar(
          content: Text(makePaid ? 'Marked PAID ✅' : 'Marked UNPAID ✅'),
          duration: const Duration(milliseconds: 900),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      AppToast.fromSnackBar(
        context,
        SnackBar(
          content: Text(
            toHumanError(e, fallback: 'Could not update this wage entry.'),
          ),
        ),
      );
    }
  }

  Future<void> _adminRemoveTeacherConfirmation({
    required BuildContext context,
    required String paymentId,
  }) async {
    final ok =
        await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Remove confirmation?'),
            content: const Text(
              'This will undo the confirmation for this payment.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Colors.red),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Remove'),
              ),
            ],
          ),
        ) ??
        false;

    if (!ok) return;

    try {
      await FirebaseDatabase.instance.ref('payments/$paymentId').update({
        'teacherConfirmed': null,
        'teacherConfirmedAt': null,
        'teacherConfirmedBy': null,
        'updatedAt': ServerValue.timestamp,
      });

      if (!context.mounted) return;
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('Confirmation removed ✅')),
      );
    } catch (e) {
      if (!context.mounted) return;
      AppToast.fromSnackBar(
        context,
        SnackBar(
          content: Text(
            toHumanError(e, fallback: 'Could not complete this action.'),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final paymentsRef = FirebaseDatabase.instance.ref('payments');
    final classesRef = FirebaseDatabase.instance.ref('classes');
    final learnersRef = FirebaseDatabase.instance.ref(
      'users',
    ); // <-- assumed path

    return Scaffold(
      backgroundColor: appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        title: const Text(
          'Wages',
          style: TextStyle(color: primaryBlue, fontWeight: FontWeight.w900),
        ),
        actions: [
          const SizedBox.shrink(),
          IconButton(
            tooltip: 'Export Excel',
            icon: const Icon(Icons.file_download_outlined),
            onPressed: () async {
              try {
                await AdminWagesExcelExporter.exportAndShareExcel();
                if (!context.mounted) return;
                AppToast.fromSnackBar(
                  context,
                  const SnackBar(content: Text('Excel exported ✅')),
                );
              } catch (e) {
                if (!context.mounted) return;
                AppToast.fromSnackBar(
                  context,
                  SnackBar(
                    content: Text(
                      toHumanError(e, fallback: 'Could not export wages file.'),
                    ),
                  ),
                );
              }
            },
          ),
        ],
      ),
      body: adminWebBodyFrame(
        context: context,
        maxWidth: 1700,
        child: StreamBuilder<DatabaseEvent>(
          stream: paymentsRef
              .orderByChild('paidAt')
              .limitToLast(_paymentsWindowSize)
              .onValue,
          builder: (context, paySnap) {
            final payRaw = paySnap.data?.snapshot.value;

            if (paySnap.hasError) {
              return const Center(child: Text('Could not load wages.'));
            }
            if (!paySnap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            if (payRaw is! Map) {
              return const Center(child: Text('No payments found.'));
            }

            // Payments list
            final payments = <Map<String, dynamic>>[];
            payRaw.forEach((k, v) {
              if (k == null || v == null) return;
              if (v is! Map) return;
              final m = v.map((kk, vv) => MapEntry(kk.toString(), vv));
              payments.add({'paymentId': k.toString(), ...m});
            });

            // Sort newest first by paidAt
            payments.sort(
              (a, b) => _asInt(b['paidAt']).compareTo(_asInt(a['paidAt'])),
            );

            // Group (NEW): teacherId -> list of payments (NO MONTH GROUPING)
            final Map<String, List<Map<String, dynamic>>> groupedByTeacher = {};
            for (final p in payments) {
              final teacherId = (p['teacherId'] ?? '').toString().trim();
              final teacherKey = teacherId.isEmpty ? 'Unknown' : teacherId;
              groupedByTeacher.putIfAbsent(teacherKey, () => []);
              groupedByTeacher[teacherKey]!.add(p);
            }

            final teacherKeys = groupedByTeacher.keys.toList()
              ..sort((a, b) {
                final aName =
                    (groupedByTeacher[a]!.isNotEmpty
                            ? (groupedByTeacher[a]!.first['teacherName'] ?? '')
                            : '')
                        .toString()
                        .trim();
                final bName =
                    (groupedByTeacher[b]!.isNotEmpty
                            ? (groupedByTeacher[b]!.first['teacherName'] ?? '')
                            : '')
                        .toString()
                        .trim();
                final aa = aName.isEmpty ? a : aName;
                final bb = bName.isEmpty ? b : bName;
                return aa.toLowerCase().compareTo(bb.toLowerCase());
              });

            if (teacherKeys.isEmpty) {
              return const Center(child: Text('No payments found.'));
            }

            return StreamBuilder<DatabaseEvent>(
              stream: classesRef.onValue,
              builder: (context, classSnap) {
                final classRaw = classSnap.data?.snapshot.value;

                final studyingByTeacher = _parseStudyingFromClasses(classRaw);
                final studyingAll = <String>{};
                for (final s in studyingByTeacher.values) {
                  studyingAll.addAll(s);
                }

                return StreamBuilder<DatabaseEvent>(
                  stream: learnersRef.onValue,
                  builder: (context, learnersSnap) {
                    final learnersRaw = learnersSnap.data?.snapshot.value;
                    final learnerMap = _parseLearners(learnersRaw);

                    // Stats header: still shows THIS MONTH global stats (same as before)
                    final nowMonthKey = _monthKeyNow();
                    final monthPayments = payments.where((p) {
                      final mk = _monthKeyFromPaidAtMs(_asInt(p['paidAt']));
                      return mk == nowMonthKey;
                    }).toList();

                    final stats = _StatsData.fromMonth(
                      monthLabel: _prettyMonthLabel(nowMonthKey),
                      monthPayments: monthPayments,
                      studyingAllUids: studyingAll,
                      asInt: _asInt,
                      asBool: _asBool,
                    );

                    // Missing uids (global) for this month
                    final paidUidsThisMonth = <String>{};
                    for (final p in monthPayments) {
                      final uid = (p['uid'] ?? '').toString().trim();
                      if (uid.isNotEmpty) paidUidsThisMonth.add(uid);
                    }
                    final missingUidsThisMonth = <String>{...studyingAll}
                      ..removeAll(paidUidsThisMonth);

                    List<_LearnerInfo> missingGlobalList() {
                      final list = <_LearnerInfo>[];
                      for (final uid in missingUidsThisMonth) {
                        list.add(
                          learnerMap[uid] ??
                              const _LearnerInfo(uid: '', name: '', serial: ''),
                        );
                        if (list.last.uid.isEmpty) {
                          list[list.length - 1] = _LearnerInfo(
                            uid: uid,
                            name: '',
                            serial: '',
                          );
                        }
                      }
                      list.sort((a, b) {
                        final aa = a.name.trim().isEmpty
                            ? a.uid
                            : a.name.trim();
                        final bb = b.name.trim().isEmpty
                            ? b.uid
                            : b.name.trim();
                        return aa.toLowerCase().compareTo(bb.toLowerCase());
                      });
                      return list;
                    }

                    return ListView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 18),
                      itemCount: teacherKeys.length + 1,
                      itemBuilder: (context, i) {
                        if (i == 0) {
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: _StatsHeaderCard(
                              data: stats,
                              onTapMissing: () {
                                _showMissingBottomSheet(
                                  context: context,
                                  title: 'Not paid yet • ${stats.monthLabel}',
                                  learners: missingGlobalList(),
                                );
                              },
                            ),
                          );
                        }

                        final tKey = teacherKeys[i - 1];
                        final teacherPayments =
                            groupedByTeacher[tKey] ?? const [];

                        return Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                              color: uiBorder.withValues(alpha: 0.8),
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.03),
                                blurRadius: 10,
                                offset: const Offset(0, 6),
                              ),
                            ],
                          ),
                          child: _TeacherSection(
                            teacherId: tKey,
                            payments: teacherPayments,
                            nowMonthKey: nowMonthKey,
                            studyingLearnerUids:
                                studyingByTeacher[tKey] ??
                                _tryMatchStudyingByTeacherName(
                                  teacherName:
                                      (teacherPayments.isNotEmpty
                                              ? (teacherPayments
                                                        .first['teacherName'] ??
                                                    '')
                                              : '')
                                          .toString()
                                          .trim(),
                                  studyingByTeacher: studyingByTeacher,
                                ),
                            learnerMap: learnerMap,
                            onTogglePaid: (paymentId, makePaid) => _togglePaid(
                              context: context,
                              paymentId: paymentId,
                              makePaid: makePaid,
                            ),
                            onRemoveTeacherConfirm: (paymentId) =>
                                _adminRemoveTeacherConfirmation(
                                  context: context,
                                  paymentId: paymentId,
                                ),
                          ),
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

// ---------------- Data models ----------------

class _LearnerInfo {
  const _LearnerInfo({
    required this.uid,
    required this.name,
    required this.serial,
  });

  final String uid;
  final String name;
  final String serial;
}

class _FinanceAlloc {
  const _FinanceAlloc({
    required this.gross,
    required this.tbpaid,
    required this.waiting,
    required this.done,
  });

  final int gross;
  final int tbpaid;
  final int waiting;
  final int done;
}

class _StatsData {
  _StatsData({
    required this.monthLabel,
    required this.paymentsCount,
    required this.paidLearnersCount,
    required this.studyingLearnersCount,
    required this.notPaidYetCount,
    required this.totalAmount,
    required this.unpaidCount,
    required this.unpaidAmount,
    required this.notConfirmedCount,
    required this.incompleteCount,
  });

  final String monthLabel;

  final int paymentsCount;
  final int paidLearnersCount;
  final int studyingLearnersCount;
  final int notPaidYetCount;

  final int totalAmount;

  final int unpaidCount;
  final int unpaidAmount;

  final int notConfirmedCount;
  final int incompleteCount;

  static _StatsData fromMonth({
    required String monthLabel,
    required List<Map<String, dynamic>> monthPayments,
    required Set<String> studyingAllUids,
    required int Function(dynamic) asInt,
    required bool Function(dynamic) asBool,
  }) {
    final paidUids = <String>{};

    int totalAmount = 0;
    int unpaidCount = 0;
    int unpaidAmount = 0;
    int notConfirmedCount = 0;
    int incompleteCount = 0;

    for (final p in monthPayments) {
      final uid = (p['uid'] ?? '').toString().trim();
      if (uid.isNotEmpty) {
        paidUids.add(uid);
      } else {
        incompleteCount++;
      }

      final amount = asInt(p['amount']);
      totalAmount += amount;

      final teacherPaid = asBool(p['teacherPaid']);
      if (!teacherPaid) {
        unpaidCount++;
        unpaidAmount += amount;
      }

      final teacherConfirmed = asBool(p['teacherConfirmed']);
      if (!teacherConfirmed) {
        notConfirmedCount++;
      }

      final learnerName = (p['learner_name'] ?? '').toString().trim();
      if (learnerName.isEmpty) incompleteCount++;
    }

    final notPaidYet = <String>{...studyingAllUids}..removeAll(paidUids);

    return _StatsData(
      monthLabel: monthLabel,
      paymentsCount: monthPayments.length,
      paidLearnersCount: paidUids.length,
      studyingLearnersCount: studyingAllUids.length,
      notPaidYetCount: notPaidYet.length,
      totalAmount: totalAmount,
      unpaidCount: unpaidCount,
      unpaidAmount: unpaidAmount,
      notConfirmedCount: notConfirmedCount,
      incompleteCount: incompleteCount,
    );
  }
}

// ---------------- Stats header card ----------------

class _StatsHeaderCard extends StatelessWidget {
  const _StatsHeaderCard({required this.data, required this.onTapMissing});

  final _StatsData data;
  final VoidCallback onTapMissing;

  static const primaryBlue = Color(0xFF1A2B48);
  static const uiBorder = Color(0xFFD1D9E0);
  String _fmtDa(int n) => '$n DA';

  Widget _tile({
    required String label,
    required String value,
    IconData? icon,
    VoidCallback? onTap,
  }) {
    final child = Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF4F7F9),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: uiBorder.withValues(alpha: 0.85)),
      ),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 18, color: primaryBlue.withValues(alpha: 0.85)),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 12,
                    color: Colors.black.withValues(alpha: 0.65),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 15,
                    color: primaryBlue,
                  ),
                ),
              ],
            ),
          ),
          if (onTap != null) ...[
            const SizedBox(width: 6),
            Icon(
              Icons.chevron_right_rounded,
              color: Colors.black.withValues(alpha: 0.35),
            ),
          ],
        ],
      ),
    );

    if (onTap == null) return child;

    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: child,
    );
  }

  Widget _smallNotice(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xFFF4F7F9),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: uiBorder.withValues(alpha: 0.85)),
      ),
      child: Text(
        text,
        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: uiBorder.withValues(alpha: 0.8)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Stats • ${data.monthLabel}',
            style: const TextStyle(
              fontWeight: FontWeight.w900,
              color: primaryBlue,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 10),
          GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 2,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 2.6,
            children: [
              _tile(
                label: 'Studying',
                value: '${data.studyingLearnersCount}',
                icon: Icons.groups_rounded,
              ),
              _tile(
                label: 'Paid learners',
                value: '${data.paidLearnersCount}',
                icon: Icons.verified_rounded,
              ),
              _tile(
                label: 'Not paid yet',
                value: '${data.notPaidYetCount}',
                icon: Icons.person_off_rounded,
                onTap: onTapMissing,
              ),
              _tile(
                label: 'Payments',
                value: '${data.paymentsCount}',
                icon: Icons.receipt_long_rounded,
              ),
              _tile(
                label: 'Unpaid (to staff)',
                value: '${data.unpaidCount} • ${_fmtDa(data.unpaidAmount)}',
                icon: Icons.payments_rounded,
              ),
              _tile(
                label: 'Total',
                value: _fmtDa(data.totalAmount),
                icon: Icons.account_balance_wallet_rounded,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              if (data.notConfirmedCount > 0)
                _smallNotice('Waiting confirmation: ${data.notConfirmedCount}'),
              if (data.incompleteCount > 0)
                _smallNotice(
                  'Some records incomplete: ${data.incompleteCount}',
                ),
              if (data.paymentsCount == 0)
                _smallNotice('No payments in this month yet.'),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------- Teacher -> Learners -> Payments ----------------

class _TeacherSection extends StatelessWidget {
  const _TeacherSection({
    required this.teacherId,
    required this.payments,
    required this.nowMonthKey,
    required this.studyingLearnerUids,
    required this.learnerMap,
    required this.onTogglePaid,
    required this.onRemoveTeacherConfirm,
  });

  final String teacherId;
  final List<Map<String, dynamic>> payments;

  // to compute "not paid yet" for current month for this teacher
  final String nowMonthKey;

  final Set<String>? studyingLearnerUids;
  final Map<String, _LearnerInfo> learnerMap;

  final Future<void> Function(String paymentId, bool makePaid) onTogglePaid;
  final Future<void> Function(String paymentId) onRemoveTeacherConfirm;

  static const primaryBlue = Color(0xFF1A2B48);

  static int _asInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString()) ?? 0;
  }

  static bool _asBool(dynamic v) {
    if (v == null) return false;
    if (v is bool) return v;
    final s = v.toString().trim().toLowerCase();
    return s == 'true' || s == '1' || s == 'yes';
  }

  static void _showMissingList({
    required BuildContext context,
    required String title,
    required List<_LearnerInfo> learners,
  }) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (_) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 15,
                          color: primaryBlue,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (learners.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    child: Text(
                      'Nothing to show 🎉',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        color: Colors.black.withValues(alpha: 0.65),
                      ),
                    ),
                  )
                else
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: learners.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final l = learners[i];
                        final displayName = l.name.isNotEmpty
                            ? l.name
                            : '(No name)';
                        final sub = [
                          if (l.serial.isNotEmpty) l.serial,
                          l.uid,
                        ].join(' • ');

                        return ListTile(
                          dense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 4,
                          ),
                          title: Text(
                            displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w900),
                          ),
                          subtitle: Text(
                            sub,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final teacherName =
        (payments.isNotEmpty ? (payments.first['teacherName'] ?? '') : '')
            .toString()
            .trim();
    final header = teacherName.isNotEmpty ? teacherName : teacherId;

    final itemsAll = [...payments]
      ..sort((a, b) => _asInt(b['paidAt']).compareTo(_asInt(a['paidAt'])));

    // Teacher totals (ALL TIME, finance model)
    int grossAll = 0;
    int teacherNetAll = 0;
    int schoolNetAll = 0;
    int confirmedCount = 0;
    for (final p in itemsAll) {
      final alloc = AdminWagesScreen._financeAlloc(p);
      final percent = AdminWagesScreen._teacherPercent(
        p['financeTeacherPercent'],
      );
      final int gross = alloc.tbpaid + alloc.done;
      final int tNet = AdminWagesScreen._netOf(gross, percent);
      final int sNet = gross - tNet;
      grossAll += gross;
      teacherNetAll += tNet;
      schoolNetAll += sNet;
      if (_asBool(p['teacherConfirmed'])) confirmedCount++;
    }

    // Teacher "not paid yet" (CURRENT MONTH only)
    final itemsThisMonth = itemsAll.where((p) {
      final mk = AdminWagesScreen._monthKeyFromPaidAtMs(_asInt(p['paidAt']));
      return mk == nowMonthKey;
    }).toList();

    final paidUidsThisMonth = <String>{};
    for (final p in itemsThisMonth) {
      final uid = (p['uid'] ?? '').toString().trim();
      if (uid.isNotEmpty) paidUidsThisMonth.add(uid);
    }

    int notPaidYet = 0;
    List<_LearnerInfo> missingList = const [];

    final studying = studyingLearnerUids ?? <String>{};
    if (studying.isNotEmpty) {
      final missingUids = <String>{...studying}..removeAll(paidUidsThisMonth);
      notPaidYet = missingUids.length;

      final list = <_LearnerInfo>[];
      for (final uid in missingUids) {
        list.add(
          learnerMap[uid] ?? _LearnerInfo(uid: uid, name: '', serial: ''),
        );
      }
      list.sort((a, b) {
        final aa = a.name.trim().isEmpty ? a.uid : a.name.trim();
        final bb = b.name.trim().isEmpty ? b.uid : b.name.trim();
        return aa.toLowerCase().compareTo(bb.toLowerCase());
      });
      missingList = list;
    }

    // Group by learner (uid) under this teacher
    final Map<String, List<Map<String, dynamic>>> byLearner = {};
    for (final p in itemsAll) {
      final uid = (p['uid'] ?? '').toString().trim();
      final key = uid.isEmpty ? 'Unknown' : uid;
      byLearner.putIfAbsent(key, () => []);
      byLearner[key]!.add(p);
    }

    final learnerKeys = byLearner.keys.toList()
      ..sort((a, b) {
        String nameA = '';
        String nameB = '';
        if (a != 'Unknown') {
          nameA = (learnerMap[a]?.name ?? '').trim();
        }
        if (b != 'Unknown') {
          nameB = (learnerMap[b]?.name ?? '').trim();
        }
        if (nameA.isEmpty) {
          nameA =
              (byLearner[a]!.isNotEmpty
                      ? (byLearner[a]!.first['learner_name'] ?? '')
                      : '')
                  .toString()
                  .trim();
        }
        if (nameB.isEmpty) {
          nameB =
              (byLearner[b]!.isNotEmpty
                      ? (byLearner[b]!.first['learner_name'] ?? '')
                      : '')
                  .toString()
                  .trim();
        }
        final aa = nameA.isEmpty ? a : nameA;
        final bb = nameB.isEmpty ? b : nameB;
        return aa.toLowerCase().compareTo(bb.toLowerCase());
      });

    final subtitle =
        'Learners: ${learnerKeys.length} • Payments: ${itemsAll.length} • Gross: $grossAll DA • Teacher net: $teacherNetAll DA • School net: $schoolNetAll DA • Confirmed: $confirmedCount';

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
      ),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        childrenPadding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              header,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontWeight: FontWeight.w900,
                color: primaryBlue,
                fontSize: 15,
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.black.withValues(alpha: 0.65),
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                ),
                if (notPaidYet > 0) ...[
                  const SizedBox(width: 8),
                  InkWell(
                    borderRadius: BorderRadius.circular(999),
                    onTap: () => _showMissingList(
                      context: context,
                      title:
                          'Not paid yet • $header • ${AdminWagesScreen._prettyMonthLabel(nowMonthKey)}',
                      learners: missingList,
                    ),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.red.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: Colors.red.withValues(alpha: 0.45),
                        ),
                      ),
                      child: Text(
                        'List ($notPaidYet)',
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 12,
                          color: Colors.red,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
        children: [
          for (final lKey in learnerKeys) ...[
            _LearnerSection(
              learnerUid: lKey,
              payments: byLearner[lKey] ?? const [],
              learnerMap: learnerMap,
              onTogglePaid: onTogglePaid,
              onRemoveTeacherConfirm: onRemoveTeacherConfirm,
            ),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}

class _LearnerSection extends StatelessWidget {
  const _LearnerSection({
    required this.learnerUid,
    required this.payments,
    required this.learnerMap,
    required this.onTogglePaid,
    required this.onRemoveTeacherConfirm,
  });

  final String learnerUid;
  final List<Map<String, dynamic>> payments;
  final Map<String, _LearnerInfo> learnerMap;

  final Future<void> Function(String paymentId, bool makePaid) onTogglePaid;
  final Future<void> Function(String paymentId) onRemoveTeacherConfirm;

  static const primaryBlue = Color(0xFF1A2B48);
  static const uiBorder = Color(0xFFD1D9E0);

  static int _asInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString()) ?? 0;
  }

  static bool _asBool(dynamic v) {
    if (v == null) return false;
    if (v is bool) return v;
    final s = v.toString().trim().toLowerCase();
    return s == 'true' || s == '1' || s == 'yes';
  }

  @override
  Widget build(BuildContext context) {
    final items = [...payments]
      ..sort((a, b) => _asInt(b['paidAt']).compareTo(_asInt(a['paidAt'])));

    // Learner name/serial
    String learnerName = '';
    String learnerSerial = '';

    if (learnerUid != 'Unknown') {
      final info = learnerMap[learnerUid];
      learnerName = (info?.name ?? '').trim();
      learnerSerial = (info?.serial ?? '').trim();
    }

    if (learnerName.isEmpty) {
      learnerName =
          (items.isNotEmpty ? (items.first['learner_name'] ?? '') : '')
              .toString()
              .trim();
    }
    if (learnerSerial.isEmpty) {
      learnerSerial =
          (items.isNotEmpty ? (items.first['learner_serial'] ?? '') : '')
              .toString()
              .trim();
    }

    if (learnerName.isEmpty) {
      learnerName = learnerUid == 'Unknown' ? 'Unknown learner' : learnerUid;
    }

    int total = 0;
    int unpaid = 0;
    for (final p in items) {
      final amount = _asInt(p['amount']);
      total += amount;
      if (!_asBool(p['teacherPaid'])) unpaid++;
    }

    final subtitle = [
      if (learnerSerial.isNotEmpty) learnerSerial,
      'Payments: ${items.length}',
      'Unpaid: $unpaid',
      'Total: $total DA',
    ].join(' • ');

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFF4F7F9),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: uiBorder.withValues(alpha: 0.85)),
      ),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              learnerName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontWeight: FontWeight.w900,
                color: primaryBlue,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.black.withValues(alpha: 0.65),
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
          ],
        ),
        children: [
          for (final p in items) ...[
            _PaymentRow(
              payment: p,
              onTogglePaid: onTogglePaid,
              onRemoveTeacherConfirm: onRemoveTeacherConfirm,
            ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

// ---------------- Existing row ----------------

class _PaymentRow extends StatelessWidget {
  const _PaymentRow({
    required this.payment,
    required this.onTogglePaid,
    required this.onRemoveTeacherConfirm,
  });

  final Map<String, dynamic> payment;
  final Future<void> Function(String paymentId, bool makePaid) onTogglePaid;
  final Future<void> Function(String paymentId) onRemoveTeacherConfirm;

  static int _asInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString()) ?? 0;
  }

  static bool _asBool(dynamic v) {
    if (v == null) return false;
    if (v is bool) return v;
    final s = v.toString().trim().toLowerCase();
    return s == 'true' || s == '1' || s == 'yes';
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _fmtYmdFromMs(int ms) {
    if (ms <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.year}-${_two(d.month)}-${_two(d.day)}';
  }

  static Widget _miniTag(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xFFF4F7F9),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFFD1D9E0)),
      ),
      child: Text(
        text,
        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12),
      ),
    );
  }

  static Widget _chip({required String text, required Color color}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.65)),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontWeight: FontWeight.w900,
          color: color,
          fontSize: 12,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final paymentId = (payment['paymentId'] ?? '').toString().trim();

    final learnerName = (payment['learner_name'] ?? '').toString().trim();
    final serial = (payment['learner_serial'] ?? '').toString().trim();

    final paidAtMs = _asInt(payment['paidAt']);
    final paidDate = _fmtYmdFromMs(paidAtMs);

    final startDate = (payment['startDate'] ?? '').toString().trim();

    final sessionsPaid = _asInt(payment['sessionsPaid']);
    final left = _asInt(payment['remindBeforeSession']);
    final amount = _asInt(payment['amount']);
    final alloc = AdminWagesScreen._financeAlloc(payment);
    final percent = AdminWagesScreen._teacherPercent(
      payment['financeTeacherPercent'],
    );
    final gross = alloc.tbpaid + alloc.done;
    final teacherNet = AdminWagesScreen._netOf(gross, percent);
    final schoolNet = gross - teacherNet;

    final isPaidStaff = _asBool(payment['teacherPaid']);
    final confirmed = _asBool(payment['teacherConfirmed']);

    final paidChipBg = isPaidStaff
        ? Colors.green.withValues(alpha: 0.15)
        : Colors.red.withValues(alpha: 0.12);
    final paidChipBorder = isPaidStaff ? Colors.green : Colors.red;
    final paidChipText = isPaidStaff ? 'PAID' : 'UNPAID';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.black.withValues(alpha: 0.06)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  learnerName.isEmpty ? '(No name)' : learnerName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    if (serial.isNotEmpty) serial,
                    if (paidDate.isNotEmpty) 'Paid: $paidDate',
                    if (startDate.isNotEmpty) 'Start: $startDate',
                  ].join(' • '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.black.withValues(alpha: 0.65),
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    _miniTag('Sessions: $sessionsPaid'),
                    _miniTag('Left: $left'),
                    _miniTag('Amount: $amount DA'),
                    _miniTag('Teacher %: $percent%'),
                    _miniTag('Gross: $gross DA'),
                    _miniTag('Teacher net: $teacherNet DA'),
                    _miniTag('School net: $schoolNet DA'),
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _chip(
                      text: confirmed ? 'CONFIRMED' : 'NOT CONFIRMED',
                      color: confirmed ? Colors.green : Colors.red,
                    ),
                    if (confirmed && paymentId.isNotEmpty)
                      OutlinedButton.icon(
                        icon: const Icon(Icons.undo_rounded, size: 18),
                        label: const Text('Unconfirm'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.red,
                          side: BorderSide(
                            color: Colors.red.withValues(alpha: 0.5),
                          ),
                        ),
                        onPressed: () => onRemoveTeacherConfirm(paymentId),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: paymentId.isEmpty
                ? null
                : () => onTogglePaid(paymentId, !isPaidStaff),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: paidChipBg,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: paidChipBorder.withValues(alpha: 0.7),
                ),
              ),
              child: Text(
                paidChipText,
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  color: paidChipBorder,
                  fontSize: 12,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
