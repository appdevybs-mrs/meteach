import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';

class PaymentDialogShared {
  static const List<String> _methods = ['Cash', 'Card', 'Transfer', 'Other'];

  // ---------- Date helpers (same behavior as your payments screen) ----------

  static String _todayYmd() {
    final d = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  static int _ymdToMs(String ymd) {
    final t = ymd.trim();
    if (t.isEmpty) return 0;
    final parts = t.split('-');
    if (parts.length != 3) return 0;
    final y = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    final d = int.tryParse(parts[2]);
    if (y == null || m == null || d == null) return 0;
    return DateTime(y, m, d).millisecondsSinceEpoch;
  }

  static String _fmtDateFromMs(dynamic ms) {
    final t = _asInt(ms);
    if (t <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(t);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  static Future<String?> _pickDateYmd({
    required BuildContext context,
    String? initialYmd,
    String helpText = 'Pick date',
  }) async {
    DateTime initial = DateTime.now();
    if ((initialYmd ?? '').trim().isNotEmpty) {
      final parts = initialYmd!.trim().split('-');
      if (parts.length == 3) {
        final y = int.tryParse(parts[0]);
        final m = int.tryParse(parts[1]);
        final d = int.tryParse(parts[2]);
        if (y != null && m != null && d != null) {
          initial = DateTime(y, m, d);
        }
      }
    }

    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2015),
      lastDate: DateTime(DateTime.now().year + 2),
      helpText: helpText,
    );

    if (picked == null) return null;
    String two(int n) => n.toString().padLeft(2, '0');
    return '${picked.year}-${two(picked.month)}-${two(picked.day)}';
  }

  // ---------- Small helpers ----------

  static void _snack(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(milliseconds: 900)),
    );
  }

  static int _asInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString()) ?? 0;
  }

  static int _parseTotalSessions(String duration) {
    final m = RegExp(r'(\d+)\s*sessions', caseSensitive: false).firstMatch(duration);
    if (m == null) return 0;
    return int.tryParse(m.group(1) ?? '') ?? 0;
  }

  static int _defaultAmount({
    required int pricePerMonth,
    required int pricePerLevel,
    required int sessionsPaid,
    required int totalSessions,
  }) {
    if (sessionsPaid == 8 && pricePerMonth > 0) return pricePerMonth;
    if (totalSessions > 0 && sessionsPaid == totalSessions && pricePerLevel > 0) {
      return pricePerLevel;
    }
    if (totalSessions > 0 && pricePerLevel > 0) {
      return ((pricePerLevel * sessionsPaid) / totalSessions).round();
    }
    return 0;
  }

  static bool _isTeacherRole(dynamic role) {
    final r = (role ?? '').toString().trim().toLowerCase();
    return r == 'teacher';
  }

  static String _teacherLabelFor(String uid, Map<String, dynamic> m) {
    final first = (m['first_name'] ?? m['firstName'] ?? '').toString().trim();
    final last = (m['last_name'] ?? m['lastName'] ?? '').toString().trim();
    final full = '$first $last'.trim();
    if (full.isNotEmpty) return full;

    final name = (m['name'] ?? m['full_name'] ?? m['fullName'] ?? '').toString().trim();
    if (name.isNotEmpty) return name;

    final email = (m['email'] ?? '').toString().trim();
    if (email.isNotEmpty) return email;

    return uid;
  }

  static Future<Map<String, String>> _loadTeachers(DatabaseReference usersRef) async {
    final teachers = <String, String>{};
    final allUsersSnap = await usersRef.get();
    final allUsersVal = allUsersSnap.value;

    if (allUsersVal is Map) {
      allUsersVal.forEach((k, v) {
        if (k == null || v == null) return;
        if (v is Map) {
          final m = v.map((kk, vv) => MapEntry(kk.toString(), vv));
          if (!_isTeacherRole(m['role'])) return;
          final uid = k.toString();
          final name = _teacherLabelFor(uid, m.cast<String, dynamic>());
          teachers[uid] = name;
        }
      });
    }

    return teachers;
  }

  // ---------- Variant / Study mode helpers ----------

  static String _readFirstNonEmpty(Map<String, dynamic> m, List<String> keys) {
    for (final k in keys) {
      final v = m[k];
      if (v == null) continue;
      final s = v.toString().trim();
      if (s.isNotEmpty) return s;
    }
    return '';
  }

  static String _normalizeDeliveryKey(String raw) {
    final v = raw.trim().toLowerCase();

    switch (v) {
      case 'inclass':
      case 'in_class':
      case 'in-class':
      case 'in class':
        return 'inclass';

      case 'flexible':
      case 'online':
        return 'flexible';

      case 'private':
      case 'vip':
      case 'live':
        return 'private';

      case 'recorded':
        return 'recorded';

      default:
        return v;
    }
  }

  static String _normalizeStudyMode(String raw) {
    final v = raw.trim().toLowerCase();

    switch (v) {
      case 'inclass':
      case 'in_class':
      case 'in-class':
      case 'in class':
        return 'inclass';

      case 'online':
        return 'online';

      default:
        return v;
    }
  }

  static String _deliveryLabelFromKey(String key) {
    switch (_normalizeDeliveryKey(key)) {
      case 'inclass':
        return 'In-Class';
      case 'flexible':
        return 'Flexible';
      case 'private':
        return 'VIP';
      case 'recorded':
        return 'Recorded';
      default:
        return key.trim();
    }
  }

  static String _studyModeLabel(String mode) {
    switch (_normalizeStudyMode(mode)) {
      case 'online':
        return 'Online';
      case 'inclass':
        return 'In-Class';
      default:
        return mode.trim();
    }
  }

  static String _variantLabel({
    required String deliveryKey,
    required String studyMode,
  }) {
    final dk = _normalizeDeliveryKey(deliveryKey);
    final sm = _normalizeStudyMode(studyMode);

    if (dk == 'private') {
      if (sm == 'online') return 'VIP Online';
      if (sm == 'inclass') return 'VIP In-Class';
      return 'VIP';
    }

    if (dk == 'inclass') return 'In-Class';
    if (dk == 'flexible') return 'Flexible';
    if (dk == 'recorded') return 'Recorded';

    return _deliveryLabelFromKey(dk);
  }

  static Map<String, String> _extractStudyFieldsFromLearnerCourseNode(
      Map<String, dynamic> node,
      ) {
    final rawDeliveryKey = _readFirstNonEmpty(node, [
      'deliveryKey',
      'delivery_key',
      'variantKey',
      'variant_key',
      'variant',
    ]);

    final rawDeliveryLabel = _readFirstNonEmpty(node, [
      'deliveryLabel',
      'delivery_label',
      'variantLabel',
      'variant_label',
      'delivery',
    ]);

    final rawStudyMode = _readFirstNonEmpty(node, [
      'studyMode',
      'study_mode',
      'privateStudyMode',
      'private_study_mode',
    ]);

    final deliveryKey = _normalizeDeliveryKey(rawDeliveryKey);
    final studyMode = _normalizeStudyMode(rawStudyMode);

    final deliveryLabel = rawDeliveryLabel.isNotEmpty
        ? rawDeliveryLabel
        : _deliveryLabelFromKey(deliveryKey);

    final studyModeLabel = studyMode.isEmpty ? '' : _studyModeLabel(studyMode);

    final variantLabel = _variantLabel(
      deliveryKey: deliveryKey,
      studyMode: studyMode,
    );

    return {
      'deliveryKey': deliveryKey,
      'deliveryLabel': deliveryLabel,
      'studyMode': studyMode,
      'studyModeLabel': studyModeLabel,
      'variantKey': deliveryKey,
      'variantLabel': variantLabel,
    };
  }

  static Future<Map<String, String>> _loadStudyFieldsForLearnerCourse({
    required DatabaseReference usersRef,
    required String uid,
    required String courseKey,
  }) async {
    final snap = await usersRef.child(uid).child('courses').child(courseKey).get();
    final raw = snap.value;
    if (raw is! Map) {
      return {
        'deliveryKey': '',
        'deliveryLabel': '',
        'studyMode': '',
        'studyModeLabel': '',
        'variantKey': '',
        'variantLabel': '',
      };
    }

    final node = raw.map((k, v) => MapEntry(k.toString(), v)).cast<String, dynamic>();
    return _extractStudyFieldsFromLearnerCourseNode(node);
  }

  // ---------- Learner summary update ----------

  static Future<void> _rebuildLearnerSummaryFromPayments({
    required FirebaseDatabase db,
    required String uid,
    required String courseKey,
  }) async {
    final paymentsRef = db.ref('payments');
    final usersRef = db.ref('users');

    final sumRef = usersRef.child(uid).child('courses').child(courseKey).child('payment_summary');
    final sumSnap = await sumRef.get();
    final sumRaw = sumSnap.value;
    final oldSum = sumRaw is Map
        ? sumRaw.map((k, v) => MapEntry(k.toString(), v))
        : <String, dynamic>{};

    final allForUidSnap = await paymentsRef.orderByChild('uid').equalTo(uid).get();
    final allForUidRaw = allForUidSnap.value;

    int totalPaid = 0;
    int sessionsPaidTotal = 0;

    int latestPaidAt = 0;
    String latestPaymentId = '';
    String latestMethod = '';
    int latestAmount = 0;
    int latestRemind = 0;

    if (allForUidRaw is Map) {
      allForUidRaw.forEach((payId, payVal) {
        if (payId == null || payVal == null) return;
        if (payVal is! Map) return;

        final p = payVal.map((k, v) => MapEntry(k.toString(), v));
        if ((p['courseKey'] ?? '').toString() != courseKey) return;

        final amount = _asInt(p['amount']);
        final sp = _asInt(p['sessionsPaid']);
        final paidAt = _asInt(p['paidAt']);

        totalPaid += amount;
        sessionsPaidTotal += sp;

        if (paidAt >= latestPaidAt) {
          latestPaidAt = paidAt;
          latestPaymentId = payId.toString();
          latestMethod = (p['method'] ?? '').toString();
          latestAmount = amount;
          latestRemind = _asInt(p['remindBeforeSession']);
        }
      });
    }

    int remind = latestRemind > 0 ? latestRemind : _asInt(oldSum['remindBeforeSession']);

    if (sessionsPaidTotal <= 0) {
      remind = 0;
    } else {
      if (remind <= 0) remind = sessionsPaidTotal;
      if (remind > sessionsPaidTotal) remind = sessionsPaidTotal;
    }

    await sumRef.update({
      ...oldSum,
      'totalPaid': totalPaid,
      'sessionsPaidTotal': sessionsPaidTotal,
      'remindBeforeSession': remind,
      'lastPaymentId': latestPaymentId,
      'lastMethod': latestMethod,
      'lastAmount': latestAmount,
      'lastPaymentAt': latestPaidAt,
      'updatedAt': ServerValue.timestamp,
    });
  }

  static Future<void> _updateLearnerSummary({
    required DatabaseReference usersRef,
    required String uid,
    required String courseKey,
    required int addSessionsPaid,
    required int addAmount,
    required String lastPaymentId,
    required String lastMethod,
    required int lastAmount,
    required int remindBeforeSession,
  }) async {
    final sumRef = usersRef.child(uid).child('courses').child(courseKey).child('payment_summary');

    await sumRef.runTransaction((current) {
      final cur = current is Map
          ? current.map((k, v) => MapEntry(k.toString(), v))
          : <String, dynamic>{};

      final oldTotalPaid = _asInt(cur['totalPaid']);
      final oldSessionsPaid = _asInt(cur['sessionsPaidTotal']);

      final newTotalPaid = oldTotalPaid + addAmount;
      final newSessionsPaidTotal = oldSessionsPaid + addSessionsPaid;

      final remind = remindBeforeSession <= 0
          ? newSessionsPaidTotal
          : (remindBeforeSession > newSessionsPaidTotal
          ? newSessionsPaidTotal
          : remindBeforeSession);

      return Transaction.success({
        ...cur,
        'totalPaid': newTotalPaid,
        'sessionsPaidTotal': newSessionsPaidTotal,
        'remindBeforeSession': remind,
        'lastPaymentAt': ServerValue.timestamp,
        'updatedAt': ServerValue.timestamp,
        'lastPaymentId': lastPaymentId,
        'lastMethod': lastMethod,
        'lastAmount': lastAmount,
      });
    });
  }

  // ======================================================================
  // PUBLIC API
  // ======================================================================

  static Future<void> showAddFromLearnerTab({
    required BuildContext context,
    required FirebaseDatabase db,
    required String uid,
    required String courseKey,
    required String courseId,
  }) async {
    final usersRef = db.ref('users');
    final coursesRef = db.ref('courses');

    final learnerSnap = await usersRef.child(uid).get();
    final learnerVal = learnerSnap.value;
    final learner = learnerVal is Map
        ? learnerVal.map((k, v) => MapEntry(k.toString(), v))
        : <String, dynamic>{};

    final courseSnap = await coursesRef.child(courseId).get();
    final courseVal = courseSnap.value;
    final course = courseVal is Map
        ? courseVal.map((k, v) => MapEntry(k.toString(), v))
        : <String, dynamic>{};

    await _showAddDialogCore(
      context: context,
      db: db,
      usersRef: usersRef,
      courseId: courseId,
      courseKey: courseKey,
      fixedUid: uid,
      fixedLearner: learner,
      fixedCourse: course,
    );
  }

  static Future<void> showAddFromAdminPayments({
    required BuildContext context,
    required FirebaseDatabase db,
  }) async {
    final usersRef = db.ref('users');
    await _showAddDialogCore(
      context: context,
      db: db,
      usersRef: usersRef,
      courseId: null,
      courseKey: null,
      fixedUid: null,
      fixedLearner: null,
      fixedCourse: null,
    );
  }

  static Future<void> showDelete({
    required BuildContext context,
    required FirebaseDatabase db,
    required Map<String, dynamic> payment,
  }) async {
    final paymentsRef = db.ref('payments');

    final paymentId = (payment['paymentId'] ?? '').toString().trim();
    final uid = (payment['uid'] ?? '').toString().trim();
    final courseKey = (payment['courseKey'] ?? '').toString().trim();

    if (paymentId.isEmpty || uid.isEmpty || courseKey.isEmpty) {
      _snack(context, 'Cannot delete: missing paymentId/uid/courseKey');
      return;
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete payment?'),
        content: const Text('This will remove the payment and update the learner summary.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    ) ??
        false;

    if (!ok) return;

    try {
      await paymentsRef.child(paymentId).remove();

      await _rebuildLearnerSummaryFromPayments(
        db: db,
        uid: uid,
        courseKey: courseKey,
      );

      _snack(context, 'Deleted ✅');
    } catch (e) {
      _snack(context, 'Delete failed: $e');
    }
  }

  static Future<void> showEdit({
    required BuildContext context,
    required FirebaseDatabase db,
    required Map<String, dynamic> payment,
  }) async {
    final paymentsRef = db.ref('payments');
    final usersRef = db.ref('users');

    final paymentId = (payment['paymentId'] ?? '').toString();
    if (paymentId.isEmpty) return;

    final teachers = await _loadTeachers(usersRef);

    int sessionsPaid = _asInt(payment['sessionsPaid']);
    int remindBeforeSession = _asInt(payment['remindBeforeSession']);
    if (remindBeforeSession <= 0) {
      remindBeforeSession = sessionsPaid > 0 ? sessionsPaid : 1;
    }

    String method = (payment['method'] ?? _methods.first).toString();
    final amountC = TextEditingController(text: _asInt(payment['amount']).toString());
    final notesC = TextEditingController(text: (payment['notes'] ?? '').toString());

    String paidDateYmd = _fmtDateFromMs(payment['paidAt']);
    if (paidDateYmd.trim().isEmpty) paidDateYmd = _todayYmd();

    String startDateYmd = (payment['startDate'] ?? '').toString();
    if (startDateYmd.trim().isEmpty) startDateYmd = _todayYmd();

    String? teacherUid = (payment['teacherId'] ?? '').toString().trim();
    if (teacherUid.isEmpty) teacherUid = null;

    String teacherName = (payment['teacherName'] ?? '').toString().trim();

    await showDialog<void>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setD) {
          return AlertDialog(
            title: const Text('Edit payment'),
            content: SizedBox(
              width: 620,
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: _DateField(
                            label: 'Paid date',
                            value: paidDateYmd,
                            onTap: () async {
                              final d = await _pickDateYmd(
                                context: context,
                                initialYmd: paidDateYmd,
                                helpText: 'Pick paid date',
                              );
                              if (d == null) return;
                              paidDateYmd = d;
                              setD(() {});
                            },
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _DateField(
                            label: 'Start date (count from)',
                            value: startDateYmd,
                            onTap: () async {
                              final d = await _pickDateYmd(
                                context: context,
                                initialYmd: startDateYmd,
                                helpText: 'Pick start date',
                              );
                              if (d == null) return;
                              startDateYmd = d;
                              setD(() {});
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _prettyDropdown<String>(
                      label: 'Teacher',
                      value: teacherUid,
                      items: {
                        null: '— Select teacher —',
                        ...teachers.map((k, v) => MapEntry(k, v)),
                      },
                      onChanged: (v) => setD(() {
                        teacherUid = v;
                        teacherName = (v == null) ? '' : (teachers[v] ?? '');
                      }),
                    ),
                    const SizedBox(height: 12),
                    _NumberPickerRow(
                      label: 'Sessions paid',
                      value: sessionsPaid,
                      min: 1,
                      max: 60,
                      onChanged: (v) {
                        sessionsPaid = v;
                        if (remindBeforeSession > sessionsPaid) {
                          remindBeforeSession = sessionsPaid;
                        }
                        setD(() {});
                      },
                    ),
                    const SizedBox(height: 10),
                    _NumberPickerRow(
                      label: 'Reminder (how many sessions left)',
                      value: remindBeforeSession,
                      min: 1,
                      max: sessionsPaid > 0 ? sessionsPaid : 1,
                      onChanged: (v) => setD(() => remindBeforeSession = v),
                    ),
                    const SizedBox(height: 12),
                    _prettyDropdown<String>(
                      label: 'Method',
                      value: method,
                      items: {for (final m in _methods) m: m},
                      onChanged: (v) => setD(() => method = v ?? method),
                    ),
                    const SizedBox(height: 12),
                    _prettyField(
                      controller: amountC,
                      label: 'Fee (editable)',
                      keyboardType: TextInputType.number,
                    ),
                    const SizedBox(height: 12),
                    _prettyField(
                      controller: notesC,
                      label: 'Notes (optional)',
                      maxLines: 2,
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
              FilledButton(
                onPressed: () async {
                  final fee = int.tryParse(amountC.text.trim()) ?? 0;
                  if (fee <= 0) {
                    _snack(context, 'Fee must be > 0');
                    return;
                  }

                  final paidAtMs = _ymdToMs(paidDateYmd);
                  if (paidAtMs <= 0) {
                    _snack(context, 'Invalid paid date.');
                    return;
                  }

                  try {
                    await paymentsRef.child(paymentId).update({
                      'sessionsPaid': sessionsPaid,
                      'remindBeforeSession': remindBeforeSession,
                      'method': method,
                      'amount': fee,
                      'teacherId': teacherUid ?? '',
                      'teacherName': teacherName,
                      'startDate': startDateYmd,
                      'notes': notesC.text.trim(),
                      'paidAt': paidAtMs,
                      'dayKey': paidDateYmd,
                      'monthKey': paidDateYmd.substring(0, 7),
                      'updatedAt': ServerValue.timestamp,
                    });

                    await _rebuildLearnerSummaryFromPayments(
                      db: db,
                      uid: (payment['uid'] ?? '').toString(),
                      courseKey: (payment['courseKey'] ?? '').toString(),
                    );

                    if (context.mounted) Navigator.pop(context);
                    _snack(context, 'Updated ✅');
                  } catch (e) {
                    _snack(context, 'Failed: $e');
                  }
                },
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    );
  }

  // ======================================================================
  // INTERNAL: One add dialog for both contexts
  // ======================================================================

  static Future<void> _showAddDialogCore({
    required BuildContext context,
    required FirebaseDatabase db,
    required DatabaseReference usersRef,
    required String? courseId,
    required String? courseKey,
    required String? fixedUid,
    required Map<String, dynamic>? fixedLearner,
    required Map<String, dynamic>? fixedCourse,
  }) async {
    final paymentsRef = db.ref('payments');
    final coursesRef = db.ref('courses');

    final teachers = await _loadTeachers(usersRef);

    String? pickedUid = fixedUid;
    Map<String, dynamic> pickedLearner = fixedLearner ?? {};

    String? pickedCourseId = courseId;
    String? pickedCourseKey = courseKey;
    Map<String, dynamic> pickedCourse = fixedCourse ?? {};

    Map<String, String> pickedStudyFields = {
      'deliveryKey': '',
      'deliveryLabel': '',
      'studyMode': '',
      'studyModeLabel': '',
      'variantKey': '',
      'variantLabel': '',
    };

    String method = _methods.first;
    int sessionsPaid = 8;
    int remindBeforeSession = 0;

    String paidDateYmd = _todayYmd();
    String startDateYmd = _todayYmd();

    String? selectedTeacherUid;
    String selectedTeacherName = '';

    final amountC = TextEditingController(text: '0');
    final notesC = TextEditingController();

    Future<void> loadCourseAndDefaults() async {
      if (pickedCourseId == null || pickedCourseId!.trim().isEmpty) return;

      final cSnap = await coursesRef.child(pickedCourseId!).get();
      final cVal = cSnap.value;
      pickedCourse = cVal is Map
          ? cVal.map((k, v) => MapEntry(k.toString(), v))
          : <String, dynamic>{};

      if (pickedUid != null &&
          pickedUid!.trim().isNotEmpty &&
          pickedCourseKey != null &&
          pickedCourseKey!.trim().isNotEmpty) {
        pickedStudyFields = await _loadStudyFieldsForLearnerCourse(
          usersRef: usersRef,
          uid: pickedUid!,
          courseKey: pickedCourseKey!,
        );
      } else {
        pickedStudyFields = {
          'deliveryKey': '',
          'deliveryLabel': '',
          'studyMode': '',
          'studyModeLabel': '',
          'variantKey': '',
          'variantLabel': '',
        };
      }

      final totalSessions = _parseTotalSessions((pickedCourse['duration'] ?? '').toString());
      sessionsPaid = (totalSessions >= 8) ? 8 : (totalSessions > 0 ? totalSessions : 8);

      final pricePerMonth = _asInt(pickedCourse['price_per_month']);
      final pricePerLevel = _asInt(pickedCourse['price_per_level']);

      amountC.text = _defaultAmount(
        pricePerMonth: pricePerMonth,
        pricePerLevel: pricePerLevel,
        sessionsPaid: sessionsPaid,
        totalSessions: totalSessions,
      ).toString();

      remindBeforeSession = sessionsPaid;
    }

    if (pickedCourse.isNotEmpty && pickedCourseId != null) {
      if (pickedUid != null &&
          pickedUid!.trim().isNotEmpty &&
          pickedCourseKey != null &&
          pickedCourseKey!.trim().isNotEmpty) {
        pickedStudyFields = await _loadStudyFieldsForLearnerCourse(
          usersRef: usersRef,
          uid: pickedUid!,
          courseKey: pickedCourseKey!,
        );
      }

      final totalSessions = _parseTotalSessions((pickedCourse['duration'] ?? '').toString());
      sessionsPaid = (totalSessions >= 8) ? 8 : (totalSessions > 0 ? totalSessions : 8);

      final pricePerMonth = _asInt(pickedCourse['price_per_month']);
      final pricePerLevel = _asInt(pickedCourse['price_per_level']);

      amountC.text = _defaultAmount(
        pricePerMonth: pricePerMonth,
        pricePerLevel: pricePerLevel,
        sessionsPaid: sessionsPaid,
        totalSessions: totalSessions,
      ).toString();

      remindBeforeSession = sessionsPaid;
    } else {
      await loadCourseAndDefaults();
    }

    await showDialog<void>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setD) {
          final totalSessions = _parseTotalSessions((pickedCourse['duration'] ?? '').toString());
          final maxSessions = totalSessions > 0 ? totalSessions : 24;

          final variantLabel = (pickedStudyFields['variantLabel'] ?? '').trim();
          final deliveryLabel = (pickedStudyFields['deliveryLabel'] ?? '').trim();
          final studyModeLabel = (pickedStudyFields['studyModeLabel'] ?? '').trim();

          String studyInfoText = '';
          if (variantLabel.isNotEmpty) {
            studyInfoText = variantLabel;
          } else if (deliveryLabel.isNotEmpty && studyModeLabel.isNotEmpty) {
            studyInfoText = '$deliveryLabel • $studyModeLabel';
          } else if (deliveryLabel.isNotEmpty) {
            studyInfoText = deliveryLabel;
          }

          return AlertDialog(
            title: const Text('Add payment'),
            content: SizedBox(
              width: 650,
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    if (pickedUid == null) ...[
                      _LearnerAutocomplete(
                        usersRef: usersRef,
                        onPicked: (uid, learnerMap) async {
                          pickedUid = uid;
                          pickedLearner = learnerMap;

                          final coursesSnap = await usersRef.child(uid).child('courses').get();
                          final coursesVal = coursesSnap.value;

                          pickedCourseKey = null;
                          pickedCourseId = null;
                          pickedCourse = {};
                          pickedStudyFields = {
                            'deliveryKey': '',
                            'deliveryLabel': '',
                            'studyMode': '',
                            'studyModeLabel': '',
                            'variantKey': '',
                            'variantLabel': '',
                          };

                          if (coursesVal is Map) {
                            final keys = coursesVal.keys
                                .map((e) => e.toString())
                                .where((k) => k.startsWith('course_'))
                                .toList()
                              ..sort();

                            if (keys.isNotEmpty) {
                              pickedCourseKey = keys.first;
                              final firstNode = coursesVal[pickedCourseKey];
                              if (firstNode is Map) {
                                final node = firstNode.map((k, v) => MapEntry(k.toString(), v));
                                pickedCourseId = (node['id'] ?? '').toString();
                                pickedStudyFields =
                                    _extractStudyFieldsFromLearnerCourseNode(
                                      node.cast<String, dynamic>(),
                                    );
                              }
                            }
                          }

                          await loadCourseAndDefaults();
                          setD(() {});
                        },
                      ),
                      const SizedBox(height: 12),
                      if (pickedUid == null)
                        const _MiniHint('Pick learner first.')
                      else
                        FutureBuilder<DataSnapshot>(
                          future: usersRef.child(pickedUid!).child('courses').get(),
                          builder: (context, snap) {
                            final v = snap.data?.value;
                            final keys = <String>[];
                            final labelByKey = <String, String>{};
                            final idByKey = <String, String>{};
                            final studyByKey = <String, Map<String, String>>{};

                            if (v is Map) {
                              v.forEach((k, val) {
                                final key = k.toString();
                                if (!key.startsWith('course_')) return;
                                if (val is Map) {
                                  final m = val.map((kk, vv) => MapEntry(kk.toString(), vv));
                                  final code = (m['course_code'] ?? '').toString().trim();
                                  final title = (m['title'] ?? '').toString().trim();
                                  final variant = _extractStudyFieldsFromLearnerCourseNode(
                                    m.cast<String, dynamic>(),
                                  );
                                  final variantLabel =
                                  (variant['variantLabel'] ?? '').trim();

                                  final pieces = <String>[
                                    if (code.isNotEmpty) code,
                                    if (title.isNotEmpty) title,
                                    if (variantLabel.isNotEmpty) variantLabel,
                                  ];

                                  keys.add(key);
                                  labelByKey[key] =
                                  pieces.isEmpty ? key : pieces.join(' — ');
                                  idByKey[key] = (m['id'] ?? '').toString();
                                  studyByKey[key] = variant;
                                }
                              });
                            }

                            keys.sort();
                            pickedCourseKey ??= keys.isNotEmpty ? keys.first : null;

                            if (keys.isEmpty) {
                              return const _MiniHint('Learner has no courses.');
                            }

                            return DropdownButtonFormField<String>(
                              value: pickedCourseKey,
                              decoration: const InputDecoration(labelText: 'Course'),
                              items: keys
                                  .map(
                                    (k) => DropdownMenuItem(
                                  value: k,
                                  child: Text(labelByKey[k] ?? k),
                                ),
                              )
                                  .toList(),
                              onChanged: (v) async {
                                pickedCourseKey = v;
                                pickedCourseId = (v == null) ? null : idByKey[v];
                                pickedCourse = {};
                                pickedStudyFields = v == null
                                    ? {
                                  'deliveryKey': '',
                                  'deliveryLabel': '',
                                  'studyMode': '',
                                  'studyModeLabel': '',
                                  'variantKey': '',
                                  'variantLabel': '',
                                }
                                    : (studyByKey[v] ??
                                    {
                                      'deliveryKey': '',
                                      'deliveryLabel': '',
                                      'studyMode': '',
                                      'studyModeLabel': '',
                                      'variantKey': '',
                                      'variantLabel': '',
                                    });

                                await loadCourseAndDefaults();
                                setD(() {});
                              },
                            );
                          },
                        ),
                      const SizedBox(height: 12),
                    ],

                    if (studyInfoText.isNotEmpty) ...[
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF4F7F9),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: Colors.black.withOpacity(0.06)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.school_rounded, size: 18),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Study type: $studyInfoText',
                                style: const TextStyle(fontWeight: FontWeight.w800),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],

                    Row(
                      children: [
                        Expanded(
                          child: _DateField(
                            label: 'Paid date',
                            value: paidDateYmd,
                            onTap: () async {
                              final d = await _pickDateYmd(
                                context: context,
                                initialYmd: paidDateYmd,
                                helpText: 'Pick paid date',
                              );
                              if (d == null) return;
                              paidDateYmd = d;
                              setD(() {});
                            },
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _DateField(
                            label: 'Start date (count from)',
                            value: startDateYmd,
                            onTap: () async {
                              final d = await _pickDateYmd(
                                context: context,
                                initialYmd: startDateYmd,
                                helpText: 'Pick start date',
                              );
                              if (d == null) return;
                              startDateYmd = d;
                              setD(() {});
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    _prettyDropdown<String>(
                      label: 'Teacher',
                      value: selectedTeacherUid,
                      items: {
                        null: '— Select teacher —',
                        ...teachers.map((k, v) => MapEntry(k, v)),
                      },
                      onChanged: (v) => setD(() {
                        selectedTeacherUid = v;
                        selectedTeacherName = (v == null) ? '' : (teachers[v] ?? '');
                      }),
                    ),
                    const SizedBox(height: 12),

                    _NumberPickerRow(
                      label: 'Sessions paid',
                      value: sessionsPaid,
                      min: 1,
                      max: maxSessions,
                      onChanged: (v) {
                        sessionsPaid = v;

                        final pricePerMonth = _asInt(pickedCourse['price_per_month']);
                        final pricePerLevel = _asInt(pickedCourse['price_per_level']);

                        amountC.text = _defaultAmount(
                          pricePerMonth: pricePerMonth,
                          pricePerLevel: pricePerLevel,
                          sessionsPaid: sessionsPaid,
                          totalSessions: totalSessions,
                        ).toString();

                        if (remindBeforeSession <= 0) remindBeforeSession = sessionsPaid;
                        if (remindBeforeSession > sessionsPaid) {
                          remindBeforeSession = sessionsPaid;
                        }

                        setD(() {});
                      },
                    ),
                    const SizedBox(height: 10),

                    _NumberPickerRow(
                      label: 'Reminder (before session)',
                      value: (remindBeforeSession <= 0 ? sessionsPaid : remindBeforeSession),
                      min: 1,
                      max: sessionsPaid > 0 ? sessionsPaid : 1,
                      onChanged: (v) => setD(() => remindBeforeSession = v),
                    ),

                    const SizedBox(height: 12),

                    _prettyDropdown<String>(
                      label: 'Method',
                      value: method,
                      items: {for (final m in _methods) m: m},
                      onChanged: (v) => setD(() => method = v ?? method),
                    ),
                    const SizedBox(height: 12),

                    _prettyField(
                      controller: amountC,
                      label: 'Fee (editable)',
                      keyboardType: TextInputType.number,
                    ),
                    const SizedBox(height: 12),

                    _prettyField(
                      controller: notesC,
                      label: 'Notes (optional)',
                      maxLines: 2,
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
              FilledButton(
                onPressed: () async {
                  if (pickedUid == null) {
                    _snack(context, 'Pick learner first.');
                    return;
                  }
                  if (pickedCourseKey == null || pickedCourseKey!.trim().isEmpty) {
                    _snack(context, 'Pick course.');
                    return;
                  }
                  if (pickedCourseId == null || pickedCourseId!.trim().isEmpty) {
                    _snack(context, 'Missing courseId.');
                    return;
                  }

                  final fee = int.tryParse(amountC.text.trim()) ?? 0;
                  if (fee <= 0) {
                    _snack(context, 'Fee must be > 0');
                    return;
                  }

                  final paidAtMs = _ymdToMs(paidDateYmd);
                  if (paidAtMs <= 0) {
                    _snack(context, 'Invalid paid date.');
                    return;
                  }

                  final learnerName =
                  '${(pickedLearner['first_name'] ?? '')} ${(pickedLearner['last_name'] ?? '')}'
                      .trim();
                  final learnerSerial = (pickedLearner['serial'] ?? '').toString();

                  final courseCode = (pickedCourse['course_code'] ?? '').toString();
                  final courseTitle = (pickedCourse['title'] ?? '').toString();

                  final remind =
                  (remindBeforeSession <= 0 ? sessionsPaid : remindBeforeSession);

                  final deliveryKey = (pickedStudyFields['deliveryKey'] ?? '').trim();
                  final deliveryLabel = (pickedStudyFields['deliveryLabel'] ?? '').trim();
                  final studyMode = (pickedStudyFields['studyMode'] ?? '').trim();
                  final studyModeLabel = (pickedStudyFields['studyModeLabel'] ?? '').trim();
                  final variantKey = (pickedStudyFields['variantKey'] ?? '').trim();
                  final variantLabel = (pickedStudyFields['variantLabel'] ?? '').trim();

                  try {
                    final newRef = paymentsRef.push();
                    final paymentId = newRef.key!;

                    await newRef.set({
                      'uid': pickedUid,
                      'courseKey': pickedCourseKey,
                      'course_id': pickedCourseId,
                      'course_code': courseCode,
                      'course_title': courseTitle,

                      'sessionsPaid': sessionsPaid,
                      'remindBeforeSession': remind,

                      'amount': fee,
                      'method': method,

                      'teacherId': selectedTeacherUid ?? '',
                      'teacherName': selectedTeacherName,

                      'startDate': startDateYmd,
                      'notes': notesC.text.trim(),

                      'paidAt': paidAtMs,
                      'createdAt': ServerValue.timestamp,

                      'learner_name': learnerName,
                      'learner_serial': learnerSerial,

                      'dayKey': paidDateYmd,
                      'monthKey': paidDateYmd.substring(0, 7),

                      // ✅ new study / variant fields
                      'deliveryKey': deliveryKey,
                      'deliveryLabel': deliveryLabel,
                      'studyMode': studyMode,
                      'studyModeLabel': studyModeLabel,
                      'variantKey': variantKey,
                      'variantLabel': variantLabel,
                    });

                    await _updateLearnerSummary(
                      usersRef: usersRef,
                      uid: pickedUid!,
                      courseKey: pickedCourseKey!,
                      addSessionsPaid: sessionsPaid,
                      addAmount: fee,
                      lastPaymentId: paymentId,
                      lastMethod: method,
                      lastAmount: fee,
                      remindBeforeSession: remind,
                    );

                    if (context.mounted) Navigator.pop(context);
                    _snack(context, 'Payment saved ✅');
                  } catch (e) {
                    _snack(context, 'Failed: $e');
                  }
                },
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    );
  }

  // ---------- Pretty UI pieces ----------

  static Widget _prettyField({
    required TextEditingController controller,
    required String label,
    TextInputType? keyboardType,
    int maxLines = 1,
  }) {
    return TextFormField(
      controller: controller,
      keyboardType: keyboardType,
      maxLines: maxLines,
      decoration: InputDecoration(
        labelText: label,
        filled: true,
        fillColor: const Color(0xFFF4F7F9),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      ),
    );
  }

  static Widget _prettyDropdown<T>({
    required String label,
    required T? value,
    required Map<T?, String> items,
    required ValueChanged<T?> onChanged,
  }) {
    return DropdownButtonFormField<T>(
      value: value,
      decoration: InputDecoration(
        labelText: label,
        filled: true,
        fillColor: const Color(0xFFF4F7F9),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      ),
      items: items.entries
          .map((e) => DropdownMenuItem<T>(value: e.key, child: Text(e.value)))
          .toList(),
      onChanged: onChanged,
    );
  }
}

// ======================================================================
// Reusable widgets
// ======================================================================

class _MiniHint extends StatelessWidget {
  const _MiniHint(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        text,
        style: TextStyle(
          color: Colors.black.withOpacity(0.6),
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _DateField extends StatelessWidget {
  const _DateField({
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          filled: true,
          fillColor: const Color(0xFFF4F7F9),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
        ),
        child: Row(
          children: [
            const Icon(Icons.calendar_month_rounded, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                value,
                style: const TextStyle(fontWeight: FontWeight.w800),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NumberPickerRow extends StatelessWidget {
  const _NumberPickerRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final String label;
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    int clamp(int v) => v < min ? min : (v > max ? max : v);

    return Row(
      children: [
        Expanded(
          child: Text(label, style: const TextStyle(fontWeight: FontWeight.w900)),
        ),
        IconButton(
          tooltip: 'Minus',
          onPressed: () => onChanged(clamp(value - 1)),
          icon: const Icon(Icons.remove_circle_outline),
        ),
        SizedBox(
          width: 56,
          child: Text(
            '$value',
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.w900),
          ),
        ),
        IconButton(
          tooltip: 'Plus',
          onPressed: () => onChanged(clamp(value + 1)),
          icon: const Icon(Icons.add_circle_outline),
        ),
      ],
    );
  }
}

class _LearnerAutocomplete extends StatefulWidget {
  const _LearnerAutocomplete({
    required this.usersRef,
    required this.onPicked,
  });

  final DatabaseReference usersRef;
  final Future<void> Function(String uid, Map<String, dynamic> learnerMap) onPicked;

  @override
  State<_LearnerAutocomplete> createState() => _LearnerAutocompleteState();
}

class _LearnerAutocompleteState extends State<_LearnerAutocomplete> {
  final _c = TextEditingController();
  String _query = '';
  List<Map<String, dynamic>> _results = [];

  @override
  void initState() {
    super.initState();
    _c.addListener(() => setState(() => _query = _c.text.trim().toLowerCase()));
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _searchNow() async {
    final q = _query;
    if (q.isEmpty) {
      setState(() => _results = []);
      return;
    }

    final snap = await widget.usersRef.get();
    final v = snap.value;
    final out = <Map<String, dynamic>>[];

    if (v is Map) {
      v.forEach((uid, raw) {
        if (raw is Map) {
          final m = raw.map((k, v) => MapEntry(k.toString(), v));
          final role = (m['role'] ?? '').toString().toLowerCase().trim();
          if (role != 'learner') return;

          final name =
          '${(m['first_name'] ?? '')} ${(m['last_name'] ?? '')}'.trim().toLowerCase();
          final email = (m['email'] ?? '').toString().toLowerCase();
          final serial = (m['serial'] ?? '').toString().toLowerCase();

          if (name.contains(q) || email.contains(q) || serial.contains(q)) {
            out.add({'uid': uid.toString(), ...m});
          }
        }
      });
    }

    out.sort(
          (a, b) => ('${a['first_name']} ${a['last_name']}')
          .compareTo('${b['first_name']} ${b['last_name']}'),
    );

    setState(() => _results = out.take(8).toList());
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TextFormField(
          controller: _c,
          decoration: InputDecoration(
            labelText: 'Learner (type name / email / serial)',
            filled: true,
            fillColor: const Color(0xFFF4F7F9),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide.none,
            ),
            suffixIcon: IconButton(
              icon: const Icon(Icons.search),
              onPressed: _searchNow,
            ),
          ),
          onChanged: (_) => _searchNow(),
        ),
        if (_results.isNotEmpty) ...[
          const SizedBox(height: 6),
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.black.withOpacity(0.08)),
            ),
            child: ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _results.length,
              separatorBuilder: (_, __) =>
                  Divider(height: 1, color: Colors.black.withOpacity(0.06)),
              itemBuilder: (context, i) {
                final r = _results[i];
                final name = '${(r['first_name'] ?? '')} ${(r['last_name'] ?? '')}'.trim();
                final serial = (r['serial'] ?? '').toString();

                return ListTile(
                  dense: true,
                  title: Text(
                    name,
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                  subtitle: Text(
                    serial,
                    style: TextStyle(color: Colors.black.withOpacity(0.6)),
                  ),
                  onTap: () async {
                    _c.text = name;
                    setState(() => _results = []);
                    await widget.onPicked(r['uid'].toString(), r);
                  },
                );
              },
            ),
          ),
        ],
      ],
    );
  }
}