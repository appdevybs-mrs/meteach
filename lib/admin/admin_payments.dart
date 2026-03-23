import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../shared/human_error.dart';
import '../shared/app_feedback.dart';

class AdminPaymentsScreen extends StatefulWidget {
  const AdminPaymentsScreen({super.key});

  static const primaryBlue = Color(0xFF1A2B48);
  static const actionOrange = Color(0xFFF98D28);
  static const appBg = Color(0xFFF4F7F9);

  @override
  State<AdminPaymentsScreen> createState() => _AdminPaymentsScreenState();
}

class _AdminPaymentsScreenState extends State<AdminPaymentsScreen> {
  final _db = FirebaseDatabase.instance;

  DatabaseReference get _paymentsRef => _db.ref('payments');
  DatabaseReference get _usersRef => _db.ref('users');
  DatabaseReference get _coursesRef => _db.ref('courses');

  String _search = '';
  String? _selectedMonthYyyyMm;
  final Set<String> _selectedPaymentIds = {};

  static const List<String> _methods = ['Cash', 'Card', 'Transfer', 'Other'];

  void _toast(String msg) {
    if (!mounted) return;
    AppToast.fromSnackBar(context, 
      SnackBar(
        content: Text(humanizeUiMessage(msg)),
        duration: const Duration(milliseconds: 900),
      ),
    );
  }

  static int _asInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString()) ?? 0;
  }

  static String _readFirstNonEmpty(Map<String, dynamic> m, List<String> keys) {
    for (final k in keys) {
      final v = m[k];
      if (v == null) continue;
      final s = v.toString().trim();
      if (s.isNotEmpty) return s;
    }
    return '';
  }

  static String _normalizeVariantKey(String raw) {
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

  static String _studyModeLabel(String raw) {
    switch (_normalizeStudyMode(raw)) {
      case 'online':
        return 'Online';
      case 'inclass':
        return 'In-Class';
      default:
        return raw.trim();
    }
  }

  static String _variantLabel({
    required String variantKey,
    required String studyMode,
  }) {
    final v = _normalizeVariantKey(variantKey);
    final m = _normalizeStudyMode(studyMode);

    if (v == 'private') {
      if (m == 'online') return 'VIP Online';
      if (m == 'inclass') return 'VIP In-Class';
      return 'VIP';
    }
    if (v == 'inclass') return 'In-Class';
    if (v == 'flexible') return 'Flexible';
    if (v == 'recorded') return 'Recorded';
    return v;
  }

  static bool _variantUsesTeacher(String variantKey) {
    final v = _normalizeVariantKey(variantKey);
    return v == 'inclass' || v == 'private';
  }

  static bool _variantUsesSessions(String variantKey) {
    final v = _normalizeVariantKey(variantKey);
    return v == 'inclass' || v == 'private' || v == 'flexible';
  }

  static bool _variantUsesReminder(String variantKey) {
    final v = _normalizeVariantKey(variantKey);
    return v == 'inclass' || v == 'private';
  }

  static bool _variantUsesExpiry(String variantKey) {
    final v = _normalizeVariantKey(variantKey);
    return v == 'flexible' || v == 'recorded';
  }

  static bool _variantUsesStartDate(String variantKey) {
    final v = _normalizeVariantKey(variantKey);
    return v == 'inclass' || v == 'private' || v == 'flexible';
  }

  static bool _variantIsRecorded(String variantKey) {
    return _normalizeVariantKey(variantKey) == 'recorded';
  }

  static bool _variantIsFlexible(String variantKey) {
    return _normalizeVariantKey(variantKey) == 'flexible';
  }

  static String _extractVariantKeyFromLearnerCourseNode(
    Map<String, dynamic> node,
  ) {
    return _normalizeVariantKey(
      _readFirstNonEmpty(node, [
        'variantKey',
        'variant_key',
        'deliveryKey',
        'delivery_key',
        'variant',
      ]),
    );
  }

  static String _extractStudyModeFromLearnerCourseNode(
    Map<String, dynamic> node,
  ) {
    return _normalizeStudyMode(
      _readFirstNonEmpty(node, [
        'studyMode',
        'study_mode',
        'privateStudyMode',
        'private_study_mode',
      ]),
    );
  }

  String _fmtDateFromMs(dynamic ms) {
    final t = _asInt(ms);
    if (t <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(t);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  String _fmtMonthFromMs(dynamic ms) {
    final t = _asInt(ms);
    if (t <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(t);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}';
  }

  String _todayYmd() {
    final d = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  int _ymdToMs(String ymd) {
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

  int _addMonthsToMs(int baseMs, int months) {
    if (baseMs <= 0 || months <= 0) return 0;
    final d = DateTime.fromMillisecondsSinceEpoch(baseMs);
    return DateTime(d.year, d.month + months, d.day).millisecondsSinceEpoch;
  }

  int _monthsBetweenMs(int startMs, int endMs) {
    if (startMs <= 0 || endMs <= 0) return 0;
    final a = DateTime.fromMillisecondsSinceEpoch(startMs);
    final b = DateTime.fromMillisecondsSinceEpoch(endMs);
    var months = (b.year - a.year) * 12 + (b.month - a.month);
    if (b.day < a.day) months -= 1;
    return months < 0 ? 0 : months;
  }

  Future<String?> _pickDateYmd({
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

  int _sumAmount(Iterable<Map<String, dynamic>> items) {
    var total = 0;
    for (final p in items) {
      total += _asInt(p['amount']);
    }
    return total;
  }

  String _fmtMoneyDa(int v) {
    final neg = v < 0;
    var s = (neg ? -v : v).toString();
    final out = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      final posFromEnd = s.length - i;
      out.write(s[i]);
      if (posFromEnd > 1 && posFromEnd % 3 == 1) out.write(' ');
    }
    return '${neg ? '-' : ''}${out.toString()} DA';
  }

  static int _parseTotalSessions(String duration) {
    final m = RegExp(
      r'(\d+)\s*sessions',
      caseSensitive: false,
    ).firstMatch(duration);
    if (m == null) return 0;
    return int.tryParse(m.group(1) ?? '') ?? 0;
  }

  static int _maxSessionsFromCourse(Map<String, dynamic> course) {
    final total = _parseTotalSessions((course['duration'] ?? '').toString());
    return total > 0 ? total : 24;
  }

  static int _defaultAmountForVariant({
    required String variantKey,
    required Map<String, dynamic> course,
    required int sessionsPaid,
    required int totalSessions,
    required int durationMonths,
  }) {
    final pricePerMonth = _asInt(course['price_per_month']);
    final pricePerLevel = _asInt(course['price_per_level']);
    final v = _normalizeVariantKey(variantKey);

    if (v == 'recorded') {
      if (pricePerMonth > 0 && durationMonths > 0) {
        return pricePerMonth * durationMonths;
      }
      return 0;
    }

    if (sessionsPaid == 8 && pricePerMonth > 0) return pricePerMonth;
    if (totalSessions > 0 &&
        sessionsPaid == totalSessions &&
        pricePerLevel > 0) {
      return pricePerLevel;
    }
    if (totalSessions > 0 && pricePerLevel > 0) {
      return ((pricePerLevel * sessionsPaid) / totalSessions).round();
    }
    return 0;
  }

  Future<void> _rebuildLearnerSummaryFromPayments({
    required String uid,
    required String courseKey,
  }) async {
    final sumRef = _usersRef
        .child(uid)
        .child('courses')
        .child(courseKey)
        .child('payment_summary');
    final oldSnap = await sumRef.get();
    final oldRaw = oldSnap.value;
    final oldSum = oldRaw is Map
        ? oldRaw.map((k, v) => MapEntry(k.toString(), v))
        : <String, dynamic>{};

    final snap = await _paymentsRef.orderByChild('uid').equalTo(uid).get();
    final v = snap.value;

    int totalPaid = 0;
    int sessionsTotal = 0;

    int lastPaidAt = 0;
    String lastPaymentId = '';
    String lastMethod = '';
    int lastAmount = 0;
    int lastRemind = 0;
    String lastVariantKey = '';

    if (v is Map) {
      for (final entry in v.entries) {
        final raw = entry.value;
        if (raw is! Map) continue;
        final m = raw.map((k, v) => MapEntry(k.toString(), v));

        if ((m['courseKey'] ?? '').toString() != courseKey) continue;

        final amount = _asInt(m['amount']);
        final sp = _asInt(m['sessionsPaid']);
        final paidAt = _asInt(m['paidAt']);
        final method = (m['method'] ?? '').toString();
        final remind = _asInt(m['remindBeforeSession']);
        final variantKey = _normalizeVariantKey(
          (m['variantKey'] ?? '').toString(),
        );

        totalPaid += amount;
        if (_variantUsesSessions(variantKey)) {
          sessionsTotal += sp;
        }

        if (paidAt >= lastPaidAt) {
          lastPaidAt = paidAt;
          lastPaymentId = entry.key.toString();
          lastMethod = method;
          lastAmount = amount;
          lastRemind = remind;
          lastVariantKey = variantKey;
        }
      }
    }

    int remindBeforeSession = 0;
    if (_variantUsesReminder(lastVariantKey)) {
      remindBeforeSession = (lastRemind > 0)
          ? lastRemind
          : _asInt(oldSum['remindBeforeSession']);
      if (sessionsTotal <= 0) {
        remindBeforeSession = 0;
      } else {
        if (remindBeforeSession <= 0) remindBeforeSession = sessionsTotal;
        if (remindBeforeSession > sessionsTotal)
          remindBeforeSession = sessionsTotal;
      }
    }

    await sumRef.update({
      ...oldSum,
      'totalPaid': totalPaid,
      'sessionsPaidTotal': sessionsTotal,
      'remindBeforeSession': remindBeforeSession,
      'lastPaymentAt': lastPaidAt,
      'lastPaymentId': lastPaymentId,
      'lastMethod': lastMethod,
      'lastAmount': lastAmount,
      'updatedAt': ServerValue.timestamp,
    });
  }

  Future<void> _writeVariantAccess({
    required String uid,
    required String courseKey,
    required String variantKey,
    required int expiresAt,
    required int months,
    required String paymentId,
  }) async {
    final v = _normalizeVariantKey(variantKey);
    if (!_variantUsesExpiry(v)) return;

    final accessNode = v == 'recorded' ? 'recorded_access' : 'flexible_access';
    final accessRef = _usersRef
        .child(uid)
        .child('courses')
        .child(courseKey)
        .child(accessNode);

    await accessRef.update({
      'expiresAt': expiresAt,
      if (v == 'recorded') 'durationMonths': months,
      if (v == 'flexible') 'expiryMonths': months,
      'lastPaymentId': paymentId,
      'updatedAt': ServerValue.timestamp,
    });
  }

  Future<void> _rebuildVariantAccessFromPayments({
    required String uid,
    required String courseKey,
    required String variantKey,
  }) async {
    final v = _normalizeVariantKey(variantKey);
    if (!_variantUsesExpiry(v)) return;

    final accessNode = v == 'recorded' ? 'recorded_access' : 'flexible_access';
    final accessRef = _usersRef
        .child(uid)
        .child('courses')
        .child(courseKey)
        .child(accessNode);

    final snap = await _paymentsRef.orderByChild('uid').equalTo(uid).get();
    final raw = snap.value;

    int latestPaidAt = 0;
    int latestExpiresAt = 0;
    int latestMonths = 0;
    String latestPaymentId = '';

    if (raw is Map) {
      for (final entry in raw.entries) {
        final payVal = entry.value;
        if (payVal is! Map) continue;

        final p = payVal.map((k, v) => MapEntry(k.toString(), v));
        if ((p['courseKey'] ?? '').toString() != courseKey) continue;

        final payVariant = _normalizeVariantKey(
          (p['variantKey'] ?? '').toString(),
        );
        if (payVariant != v) continue;

        final paidAt = _asInt(p['paidAt']);
        if (paidAt >= latestPaidAt) {
          latestPaidAt = paidAt;
          latestExpiresAt = _asInt(p['expiresAt']);
          latestMonths = v == 'recorded'
              ? _asInt(p['durationMonths'])
              : _asInt(p['expiryMonths']);
          latestPaymentId = entry.key.toString();
        }
      }
    }

    if (latestPaymentId.isEmpty) {
      await accessRef.remove();
      return;
    }

    await accessRef.update({
      'expiresAt': latestExpiresAt,
      if (v == 'recorded') 'durationMonths': latestMonths,
      if (v == 'flexible') 'expiryMonths': latestMonths,
      'lastPaymentId': latestPaymentId,
      'updatedAt': ServerValue.timestamp,
    });
  }

  Future<bool> _isDuplicatePayment({
    required String uid,
    required String courseKey,
    required String variantKey,
    required int sessionsPaid,
    required int durationMonths,
    required int amount,
    required String dayKey,
  }) async {
    final snap = await _paymentsRef.limitToLast(200).get();
    final v = snap.value;
    if (v is! Map) return false;

    for (final entry in v.entries) {
      final val = entry.value;
      if (val is! Map) continue;
      final m = val.map((k, v) => MapEntry(k.toString(), v));
      final existingVariant = _normalizeVariantKey(
        (m['variantKey'] ?? '').toString(),
      );

      final sameBase =
          (m['uid'] ?? '') == uid &&
          (m['courseKey'] ?? '') == courseKey &&
          _asInt(m['amount']) == amount &&
          (m['dayKey'] ?? '') == dayKey &&
          existingVariant == _normalizeVariantKey(variantKey);

      if (!sameBase) continue;

      if (_variantIsRecorded(variantKey)) {
        if (_asInt(m['durationMonths']) == durationMonths) return true;
      } else {
        if (_asInt(m['sessionsPaid']) == sessionsPaid) return true;
      }
    }
    return false;
  }

  Future<Map<String, String>> _loadStudyFieldsForLearnerCourse({
    required String uid,
    required String courseKey,
  }) async {
    final snap = await _usersRef
        .child(uid)
        .child('courses')
        .child(courseKey)
        .get();
    final raw = snap.value;
    if (raw is! Map) {
      return {
        'variantKey': '',
        'studyMode': '',
        'studyModeLabel': '',
        'variantLabel': '',
      };
    }

    final node = raw
        .map((k, v) => MapEntry(k.toString(), v))
        .cast<String, dynamic>();
    final variantKey = _extractVariantKeyFromLearnerCourseNode(node);
    final studyMode = _extractStudyModeFromLearnerCourseNode(node);

    return {
      'variantKey': variantKey,
      'studyMode': studyMode,
      'studyModeLabel': studyMode.isEmpty ? '' : _studyModeLabel(studyMode),
      'variantLabel': _variantLabel(
        variantKey: variantKey,
        studyMode: studyMode,
      ),
    };
  }

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DatabaseEvent>(
      stream: _paymentsRef.onValue,
      builder: (context, snap) {
        if (snap.hasError) {
          return const Scaffold(
            body: Center(child: Text('Error loading payments.')),
          );
        }
        if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final raw = snap.data?.snapshot.value;
        final all = <Map<String, dynamic>>[];
        if (raw is Map) {
          raw.forEach((k, val) {
            if (val is Map) {
              final m = val.map((kk, vv) => MapEntry(kk.toString(), vv));
              m['paymentId'] = k.toString();
              all.add(m.cast<String, dynamic>());
            }
          });
        }

        all.sort(
          (a, b) => _asInt(a['createdAt']).compareTo(_asInt(b['createdAt'])),
        );

        final monthsSet = <String>{};
        for (final p in all) {
          final mm = _fmtMonthFromMs(p['paidAt']);
          if (mm.isNotEmpty) monthsSet.add(mm);
        }
        final months = monthsSet.toList()..sort((a, b) => b.compareTo(a));

        if (_selectedMonthYyyyMm != null &&
            !monthsSet.contains(_selectedMonthYyyyMm)) {
          _selectedMonthYyyyMm = null;
        }

        final s = _search.trim().toLowerCase();
        final searchFiltered = s.isEmpty
            ? all
            : all.where((p) {
                final learnerName = (p['learner_name'] ?? '')
                    .toString()
                    .toLowerCase();
                final serial = (p['learner_serial'] ?? '')
                    .toString()
                    .toLowerCase();
                final code = (p['course_code'] ?? '').toString().toLowerCase();
                final title = (p['course_title'] ?? '')
                    .toString()
                    .toLowerCase();
                final teacher = (p['teacherName'] ?? '')
                    .toString()
                    .toLowerCase();
                final notes = (p['notes'] ?? '').toString().toLowerCase();
                final paidDate = _fmtDateFromMs(p['paidAt']).toLowerCase();
                final startDate = (p['startDate'] ?? '')
                    .toString()
                    .toLowerCase();
                final expiryDate = _fmtDateFromMs(p['expiresAt']).toLowerCase();
                final variant = _variantLabel(
                  variantKey: (p['variantKey'] ?? '').toString(),
                  studyMode: (p['studyMode'] ?? '').toString(),
                ).toLowerCase();

                return learnerName.contains(s) ||
                    serial.contains(s) ||
                    code.contains(s) ||
                    title.contains(s) ||
                    teacher.contains(s) ||
                    notes.contains(s) ||
                    paidDate.contains(s) ||
                    startDate.contains(s) ||
                    expiryDate.contains(s) ||
                    variant.contains(s);
              }).toList();

        final visible = (_selectedMonthYyyyMm == null)
            ? searchFiltered
            : searchFiltered
                  .where(
                    (p) => _fmtMonthFromMs(p['paidAt']) == _selectedMonthYyyyMm,
                  )
                  .toList();

        final today = _todayYmd();
        final todayTotal = _sumAmount(
          all.where((p) => (p['dayKey'] ?? '') == today),
        );
        final visibleTotal = _sumAmount(visible);
        final monthTotal = _sumAmount(
          (_selectedMonthYyyyMm == null)
              ? all
              : all.where(
                  (p) => _fmtMonthFromMs(p['paidAt']) == _selectedMonthYyyyMm,
                ),
        );

        int selectedTotal = 0;
        int selectedCount = 0;
        if (_selectedPaymentIds.isNotEmpty) {
          final visibleById = <String, Map<String, dynamic>>{};
          for (final p in visible) {
            visibleById[(p['paymentId'] ?? '').toString()] = p;
          }

          final toRemove = <String>[];
          for (final id in _selectedPaymentIds) {
            final p = visibleById[id];
            if (p == null) {
              toRemove.add(id);
            } else {
              selectedCount++;
              selectedTotal += _asInt(p['amount']);
            }
          }

          if (toRemove.isNotEmpty) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              setState(() {
                _selectedPaymentIds.removeAll(toRemove);
              });
            });
          }
        }

        final todayPill = _Pill(
          icon: Icons.today_rounded,
          text: 'Today: ${_fmtMoneyDa(todayTotal)}',
          strong: true,
        );

        return Scaffold(
          backgroundColor: AdminPaymentsScreen.appBg,
          appBar: AppBar(
            backgroundColor: Colors.white,
            elevation: 0,
            surfaceTintColor: Colors.white,
            iconTheme: const IconThemeData(
              color: AdminPaymentsScreen.primaryBlue,
            ),
            title: const Text(
              'Payments',
              style: TextStyle(
                color: AdminPaymentsScreen.primaryBlue,
                fontWeight: FontWeight.w900,
              ),
            ),
            actions: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Center(child: todayPill),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Add payment',
                icon: const Icon(
                  Icons.add_card_rounded,
                  color: AdminPaymentsScreen.actionOrange,
                ),
                onPressed: () => _openAddPaymentDialog(),
              ),
              const SizedBox(width: 6),
            ],
          ),
          body: Column(
            children: [
              Container(
                color: Colors.white,
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                child: TextField(
                  onChanged: (v) => setState(() => _search = v),
                  decoration: InputDecoration(
                    hintText:
                        'Search: learner, serial, variant, teacher, course, notes, dates…',
                    prefixIcon: const Icon(Icons.search),
                    filled: true,
                    fillColor: AdminPaymentsScreen.appBg,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                  ),
                ),
              ),
              Container(
                color: Colors.white,
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _SmallDropdown<String?>(
                        label: 'Month',
                        value: _selectedMonthYyyyMm,
                        items: [
                          const DropdownMenuItem<String?>(
                            value: null,
                            child: Text('All'),
                          ),
                          ...months.map(
                            (m) => DropdownMenuItem<String?>(
                              value: m,
                              child: Text(m),
                            ),
                          ),
                        ],
                        onChanged: (v) => setState(() {
                          _selectedMonthYyyyMm = v;
                        }),
                      ),
                      const SizedBox(width: 10),
                      _Pill(
                        icon: Icons.summarize_rounded,
                        text: 'Total: ${_fmtMoneyDa(visibleTotal)}',
                        strong: true,
                      ),
                      const SizedBox(width: 8),
                      _Pill(
                        icon: Icons.calendar_view_month_rounded,
                        text: 'Month: ${_fmtMoneyDa(monthTotal)}',
                      ),
                      if (selectedCount > 0) ...[
                        const SizedBox(width: 8),
                        _Pill(
                          icon: Icons.check_circle_rounded,
                          text:
                              'Selected ($selectedCount): ${_fmtMoneyDa(selectedTotal)}',
                          color: AdminPaymentsScreen.actionOrange.withValues(alpha: 
                            0.18,
                          ),
                          borderColor: AdminPaymentsScreen.actionOrange
                              .withValues(alpha: 0.35),
                        ),
                        IconButton(
                          tooltip: 'Clear selection',
                          onPressed: () =>
                              setState(() => _selectedPaymentIds.clear()),
                          icon: const Icon(Icons.close, size: 18),
                        ),
                      ],
                      const SizedBox(width: 6),
                      IconButton(
                        tooltip: 'Clear filters',
                        onPressed: () {
                          setState(() {
                            _selectedMonthYyyyMm = null;
                            _selectedPaymentIds.clear();
                          });
                        },
                        icon: const Icon(Icons.filter_alt_off),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final tableWidth = constraints.maxWidth < 1300
                        ? 1300.0
                        : constraints.maxWidth;

                    if (visible.isEmpty) {
                      return const Center(child: Text('No payments found.'));
                    }

                    return SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SizedBox(
                        width: tableWidth,
                        height: constraints.maxHeight,
                        child: Column(
                          children: [
                            Container(
                              color: Colors.white,
                              alignment: Alignment.center,
                              padding: const EdgeInsets.fromLTRB(
                                12,
                                10,
                                12,
                                10,
                              ),
                              child: ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxWidth: tableWidth,
                                ),
                                child: const _TableHeaderRow(),
                              ),
                            ),
                            Divider(
                              height: 1,
                              color: Colors.black.withValues(alpha: 0.07),
                            ),
                            Expanded(
                              child: ListView.separated(
                                padding: const EdgeInsets.fromLTRB(0, 0, 0, 18),
                                itemCount: visible.length,
                                separatorBuilder: (_, _) => Divider(
                                  height: 1,
                                  color: Colors.black.withValues(alpha: 0.07),
                                ),
                                itemBuilder: (context, i) {
                                  final p = visible[i];
                                  final idx = i + 1;

                                  final paymentId = (p['paymentId'] ?? '')
                                      .toString();
                                  final isSelected = _selectedPaymentIds
                                      .contains(paymentId);

                                  final paidDate = _fmtDateFromMs(p['paidAt']);
                                  final startDate = (p['startDate'] ?? '')
                                      .toString();
                                  final expiresAt = _fmtDateFromMs(
                                    p['expiresAt'],
                                  );
                                  final learnerName = (p['learner_name'] ?? '')
                                      .toString();
                                  final amount = _asInt(p['amount']);
                                  final teacher = (p['teacherName'] ?? '')
                                      .toString();
                                  final courseTitle = (p['course_title'] ?? '')
                                      .toString();
                                  final notes = (p['notes'] ?? '').toString();
                                  final variantText = _variantLabel(
                                    variantKey: (p['variantKey'] ?? '')
                                        .toString(),
                                    studyMode: (p['studyMode'] ?? '')
                                        .toString(),
                                  );

                                  final detail =
                                      _variantIsRecorded(
                                        (p['variantKey'] ?? '').toString(),
                                      )
                                      ? 'Months: ${_asInt(p['durationMonths'])}'
                                      : _variantUsesSessions(
                                          (p['variantKey'] ?? '').toString(),
                                        )
                                      ? 'Sessions: ${_asInt(p['sessionsPaid'])}'
                                      : '—';

                                  final baseRowBg = (i % 2 == 0)
                                      ? Colors.white
                                      : AdminPaymentsScreen.appBg.withValues(alpha: 
                                          0.7,
                                        );
                                  final rowBg = isSelected
                                      ? AdminPaymentsScreen.actionOrange
                                            .withValues(alpha: 0.14)
                                      : baseRowBg;

                                  final selectionMode =
                                      _selectedPaymentIds.isNotEmpty;

                                  return InkWell(
                                    onLongPress: () => setState(() {
                                      if (isSelected) {
                                        _selectedPaymentIds.remove(paymentId);
                                      } else {
                                        _selectedPaymentIds.add(paymentId);
                                      }
                                    }),
                                    onTap: () async {
                                      if (selectionMode) {
                                        setState(() {
                                          if (isSelected) {
                                            _selectedPaymentIds.remove(
                                              paymentId,
                                            );
                                          } else {
                                            _selectedPaymentIds.add(paymentId);
                                          }
                                        });
                                        return;
                                      }
                                      await _openEditPaymentDialog(p);
                                    },
                                    child: Container(
                                      color: rowBg,
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 10,
                                        horizontal: 6,
                                      ),
                                      child: Row(
                                        children: [
                                          SizedBox(
                                            width: 34,
                                            child: Center(
                                              child: AnimatedSwitcher(
                                                duration: const Duration(
                                                  milliseconds: 120,
                                                ),
                                                child: isSelected
                                                    ? const Icon(
                                                        Icons.check_circle,
                                                        size: 18,
                                                        color:
                                                            AdminPaymentsScreen
                                                                .actionOrange,
                                                      )
                                                    : Icon(
                                                        Icons
                                                            .radio_button_unchecked,
                                                        size: 18,
                                                        color:
                                                            AdminPaymentsScreen
                                                                .primaryBlue
                                                                .withValues(alpha: 
                                                                  0.25,
                                                                ),
                                                      ),
                                              ),
                                            ),
                                          ),
                                          _cell(
                                            '#$idx',
                                            flex: 1,
                                            isStrong: true,
                                          ),
                                          _cell(
                                            paidDate.isEmpty ? '—' : paidDate,
                                            flex: 2,
                                          ),
                                          _cell(
                                            learnerName.isEmpty
                                                ? '—'
                                                : learnerName,
                                            flex: 3,
                                          ),
                                          _cell(variantText, flex: 2),
                                          _cell(
                                            '$amount',
                                            flex: 2,
                                            isStrong: true,
                                          ),
                                          _cell(detail, flex: 2),
                                          _cell(
                                            teacher.isEmpty ? '—' : teacher,
                                            flex: 3,
                                          ),
                                          _cell(
                                            courseTitle.isEmpty
                                                ? '—'
                                                : courseTitle,
                                            flex: 3,
                                          ),
                                          _cell(
                                            startDate.isNotEmpty
                                                ? startDate
                                                : (expiresAt.isNotEmpty
                                                      ? expiresAt
                                                      : '—'),
                                            flex: 2,
                                          ),
                                          _cell(
                                            notes.isEmpty ? '—' : notes,
                                            flex: 4,
                                          ),
                                          SizedBox(
                                            width: 40,
                                            child: Align(
                                              alignment: Alignment.centerRight,
                                              child: PopupMenuButton<String>(
                                                tooltip: 'Actions',
                                                onSelected: (a) async {
                                                  if (a == 'edit') {
                                                    await _openEditPaymentDialog(
                                                      p,
                                                    );
                                                  } else if (a == 'delete') {
                                                    await _deletePayment(p);
                                                  }
                                                },
                                                itemBuilder: (_) => const [
                                                  PopupMenuItem(
                                                    value: 'edit',
                                                    child: Text('Edit'),
                                                  ),
                                                  PopupMenuDivider(),
                                                  PopupMenuItem(
                                                    value: 'delete',
                                                    child: Text('Delete'),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
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
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  static Widget _cell(String text, {required int flex, bool isStrong = false}) {
    return Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontWeight: isStrong ? FontWeight.w900 : FontWeight.w700,
            color: AdminPaymentsScreen.primaryBlue.withValues(alpha: 
              isStrong ? 1 : 0.85,
            ),
            fontSize: 12.5,
          ),
        ),
      ),
    );
  }

  // ----------------- ADD PAYMENT -----------------

  Future<void> _openAddPaymentDialog() async {
    String? pickedUid;
    String? pickedCourseId;
    String? pickedCourseKey;

    String method = _methods.first;
    String pickedVariantKey = '';
    String pickedStudyMode = '';
    String pickedStudyModeLabel = '';
    int sessionsPaid = 8;
    int remindBeforeSession = 0;
    int expiryMonths = 1;
    int durationMonths = 1;

    final amountC = TextEditingController(text: '0');
    final notesC = TextEditingController();

    String paidDateYmd = _todayYmd();
    String startDateYmd = _todayYmd();

    Map<String, dynamic> pickedLearner = {};
    Map<String, dynamic> pickedCourse = {};

    String? selectedTeacherUid;
    String? selectedTeacherName;

    bool isSaving = false;

    Future<void> loadCourseAndDefaults() async {
      if (pickedCourseId == null || pickedCourseId!.trim().isEmpty) return;

      final cSnap = await _coursesRef.child(pickedCourseId!).get();
      final cVal = cSnap.value;
      pickedCourse = cVal is Map
          ? cVal.map((k, v) => MapEntry(k.toString(), v))
          : <String, dynamic>{};

      if (pickedUid != null &&
          pickedUid!.trim().isNotEmpty &&
          pickedCourseKey != null &&
          pickedCourseKey!.trim().isNotEmpty) {
        final study = await _loadStudyFieldsForLearnerCourse(
          uid: pickedUid!,
          courseKey: pickedCourseKey!,
        );
        pickedVariantKey = study['variantKey'] ?? '';
        pickedStudyMode = study['studyMode'] ?? '';
        pickedStudyModeLabel = study['studyModeLabel'] ?? '';
      }

      final totalSessions = _parseTotalSessions(
        (pickedCourse['duration'] ?? '').toString(),
      );

      if (_variantUsesSessions(pickedVariantKey)) {
        sessionsPaid = (totalSessions >= 8)
            ? 8
            : (totalSessions > 0 ? totalSessions : 8);
      } else {
        sessionsPaid = 0;
      }

      if (_variantUsesReminder(pickedVariantKey)) {
        remindBeforeSession = sessionsPaid > 0 ? sessionsPaid : 1;
      } else {
        remindBeforeSession = 0;
      }

      if (_variantIsFlexible(pickedVariantKey)) expiryMonths = 1;
      if (_variantIsRecorded(pickedVariantKey)) durationMonths = 1;

      amountC.text = _defaultAmountForVariant(
        variantKey: pickedVariantKey,
        course: pickedCourse,
        sessionsPaid: sessionsPaid,
        totalSessions: totalSessions,
        durationMonths: durationMonths,
      ).toString();

      if (!_variantUsesTeacher(pickedVariantKey)) {
        selectedTeacherUid = null;
        selectedTeacherName = null;
      }
    }

    await showDialog<void>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setD) {
          final totalSessions = _parseTotalSessions(
            (pickedCourse['duration'] ?? '').toString(),
          );
          final maxSessions = _maxSessionsFromCourse(pickedCourse);
          final usesTeacher = _variantUsesTeacher(pickedVariantKey);
          final usesSessions = _variantUsesSessions(pickedVariantKey);
          final usesReminder = _variantUsesReminder(pickedVariantKey);
          final usesStartDate = _variantUsesStartDate(pickedVariantKey);
          final usesExpiry = _variantUsesExpiry(pickedVariantKey);
          final isRecorded = _variantIsRecorded(pickedVariantKey);

          final expiryPreviewBaseMs = _variantIsFlexible(pickedVariantKey)
              ? _ymdToMs(startDateYmd)
              : _ymdToMs(paidDateYmd);

          final expiryPreviewMs = usesExpiry
              ? _addMonthsToMs(
                  expiryPreviewBaseMs,
                  isRecorded ? durationMonths : expiryMonths,
                )
              : 0;
          final expiryPreviewYmd = usesExpiry
              ? _fmtDateFromMs(expiryPreviewMs)
              : '';

          return AlertDialog(
            title: const Text('Add payment'),
            content: SizedBox(
              width: 620,
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    _LearnerAutocomplete(
                      usersRef: _usersRef,
                      onPicked: (uid, learnerMap) async {
                        pickedUid = uid;
                        pickedLearner = learnerMap;

                        final coursesSnap = await _usersRef
                            .child(uid)
                            .child('courses')
                            .get();
                        final coursesVal = coursesSnap.value;

                        pickedCourseKey = null;
                        pickedCourseId = null;
                        pickedCourse = {};
                        pickedVariantKey = '';
                        pickedStudyMode = '';
                        pickedStudyModeLabel = '';

                        if (coursesVal is Map) {
                          final keys =
                              coursesVal.keys
                                  .map((e) => e.toString())
                                  .where((k) => k.startsWith('course_'))
                                  .toList()
                                ..sort();

                          if (keys.isNotEmpty) {
                            pickedCourseKey = keys.first;
                            final firstNode = coursesVal[pickedCourseKey];
                            if (firstNode is Map) {
                              final node = firstNode.map(
                                (k, v) => MapEntry(k.toString(), v),
                              );
                              pickedCourseId = (node['id'] ?? '').toString();
                              pickedVariantKey =
                                  _extractVariantKeyFromLearnerCourseNode(
                                    node.cast<String, dynamic>(),
                                  );
                              pickedStudyMode =
                                  _extractStudyModeFromLearnerCourseNode(
                                    node.cast<String, dynamic>(),
                                  );
                              pickedStudyModeLabel = pickedStudyMode.isEmpty
                                  ? ''
                                  : _studyModeLabel(pickedStudyMode);
                            }
                          }
                        }

                        await loadCourseAndDefaults();
                        setD(() {});
                      },
                    ),
                    const SizedBox(height: 12),
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
                        if (usesStartDate) ...[
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
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (pickedUid == null)
                      const _MiniHint('Pick learner first.')
                    else
                      FutureBuilder<DataSnapshot>(
                        future: _usersRef
                            .child(pickedUid!)
                            .child('courses')
                            .get(),
                        builder: (context, snap) {
                          final v = snap.data?.value;
                          final keys = <String>[];
                          final labelByKey = <String, String>{};
                          final idByKey = <String, String>{};
                          final variantByKey = <String, String>{};
                          final studyModeByKey = <String, String>{};

                          if (v is Map) {
                            v.forEach((k, val) {
                              final key = k.toString();
                              if (!key.startsWith('course_')) return;
                              if (val is Map) {
                                final m = val.map(
                                  (kk, vv) => MapEntry(kk.toString(), vv),
                                );
                                final code = (m['course_code'] ?? '')
                                    .toString()
                                    .trim();
                                final title = (m['title'] ?? '')
                                    .toString()
                                    .trim();
                                final variantKey =
                                    _extractVariantKeyFromLearnerCourseNode(
                                      m.cast<String, dynamic>(),
                                    );
                                final studyMode =
                                    _extractStudyModeFromLearnerCourseNode(
                                      m.cast<String, dynamic>(),
                                    );
                                final label = [
                                  if (code.isNotEmpty) code,
                                  if (title.isNotEmpty) title,
                                  _variantLabel(
                                    variantKey: variantKey,
                                    studyMode: studyMode,
                                  ),
                                ].join(' — ');
                                keys.add(key);
                                labelByKey[key] = label;
                                idByKey[key] = (m['id'] ?? '').toString();
                                variantByKey[key] = variantKey;
                                studyModeByKey[key] = studyMode;
                              }
                            });
                          }
                          keys.sort();

                          if (keys.isEmpty)
                            return const _MiniHint('Learner has no courses.');

                          pickedCourseKey ??= keys.first;

                          return DropdownButtonFormField<String>(
                            initialValue: pickedCourseKey,
                            decoration: const InputDecoration(
                              labelText: 'Course',
                            ),
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
                              pickedVariantKey = v == null
                                  ? ''
                                  : (variantByKey[v] ?? '');
                              pickedStudyMode = v == null
                                  ? ''
                                  : (studyModeByKey[v] ?? '');
                              pickedStudyModeLabel = pickedStudyMode.isEmpty
                                  ? ''
                                  : _studyModeLabel(pickedStudyMode);

                              await loadCourseAndDefaults();
                              setD(() {});
                            },
                          );
                        },
                      ),
                    const SizedBox(height: 12),

                    if (pickedVariantKey.trim().isNotEmpty) ...[
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AdminPaymentsScreen.appBg,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: Colors.black.withValues(alpha: 0.06),
                          ),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.school_rounded, size: 18),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Study type: ${_variantLabel(variantKey: pickedVariantKey, studyMode: pickedStudyMode)}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],

                    if (usesTeacher) ...[
                      _TeacherDropdownFromUsers(
                        usersRef: _usersRef,
                        valueUid: selectedTeacherUid,
                        fallbackName: selectedTeacherName,
                        onChanged: (uid, name) => setD(() {
                          selectedTeacherUid = uid;
                          selectedTeacherName = name;
                        }),
                      ),
                      const SizedBox(height: 12),
                    ],

                    if (usesSessions) ...[
                      _NumberPickerRow(
                        label: 'Sessions paid',
                        value: sessionsPaid,
                        min: 1,
                        max: maxSessions,
                        onChanged: (v) {
                          sessionsPaid = v;
                          amountC.text = _defaultAmountForVariant(
                            variantKey: pickedVariantKey,
                            course: pickedCourse,
                            sessionsPaid: sessionsPaid,
                            totalSessions: totalSessions,
                            durationMonths: durationMonths,
                          ).toString();

                          if (usesReminder) {
                            if (remindBeforeSession <= 0)
                              remindBeforeSession = sessionsPaid;
                            if (remindBeforeSession > sessionsPaid) {
                              remindBeforeSession = sessionsPaid;
                            }
                          }
                          setD(() {});
                        },
                      ),
                      const SizedBox(height: 10),
                    ],

                    if (usesReminder) ...[
                      _NumberPickerRow(
                        label: 'Reminder when left',
                        value: (remindBeforeSession <= 0
                            ? sessionsPaid
                            : remindBeforeSession),
                        min: 1,
                        max: (sessionsPaid > 0 ? sessionsPaid : 1),
                        onChanged: (v) => setD(() => remindBeforeSession = v),
                      ),
                      const SizedBox(height: 10),
                    ],

                    if (_variantIsFlexible(pickedVariantKey)) ...[
                      _NumberPickerRow(
                        label: 'Expires in months',
                        value: expiryMonths,
                        min: 1,
                        max: 12,
                        onChanged: (v) => setD(() => expiryMonths = v),
                      ),
                      const SizedBox(height: 10),
                      _InfoLine(
                        label: 'Expires on',
                        value: expiryPreviewYmd.isEmpty
                            ? '—'
                            : expiryPreviewYmd,
                      ),
                      const SizedBox(height: 10),
                    ],

                    if (_variantIsRecorded(pickedVariantKey)) ...[
                      _NumberPickerRow(
                        label: 'Duration months',
                        value: durationMonths,
                        min: 1,
                        max: 12,
                        onChanged: (v) {
                          durationMonths = v;
                          amountC.text = _defaultAmountForVariant(
                            variantKey: pickedVariantKey,
                            course: pickedCourse,
                            sessionsPaid: sessionsPaid,
                            totalSessions: totalSessions,
                            durationMonths: durationMonths,
                          ).toString();
                          setD(() {});
                        },
                      ),
                      const SizedBox(height: 10),
                      _InfoLine(
                        label: 'Expires on',
                        value: expiryPreviewYmd.isEmpty
                            ? '—'
                            : expiryPreviewYmd,
                      ),
                      const SizedBox(height: 10),
                    ],

                    DropdownButtonFormField<String>(
                      initialValue: method,
                      decoration: const InputDecoration(labelText: 'Method'),
                      items: _methods
                          .map(
                            (m) => DropdownMenuItem(value: m, child: Text(m)),
                          )
                          .toList(),
                      onChanged: (v) => setD(() => method = v ?? method),
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: amountC,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Fee (editable)',
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: notesC,
                      maxLines: 2,
                      decoration: const InputDecoration(
                        labelText: 'Notes (optional)',
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: isSaving
                    ? null
                    : () async {
                        if (pickedUid == null) {
                          _toast('Pick learner first.');
                          return;
                        }
                        if (pickedCourseKey == null ||
                            pickedCourseKey!.trim().isEmpty) {
                          _toast('Pick course.');
                          return;
                        }

                        final fee = int.tryParse(amountC.text.trim()) ?? 0;
                        if (fee <= 0) {
                          _toast('Fee must be > 0');
                          return;
                        }

                        final paidAtMs = _ymdToMs(paidDateYmd);
                        if (paidAtMs <= 0) {
                          _toast('Invalid paid date.');
                          return;
                        }

                        final usesTeacher = _variantUsesTeacher(
                          pickedVariantKey,
                        );
                        final usesSessions = _variantUsesSessions(
                          pickedVariantKey,
                        );
                        final usesReminder = _variantUsesReminder(
                          pickedVariantKey,
                        );
                        final usesStartDate = _variantUsesStartDate(
                          pickedVariantKey,
                        );
                        final usesExpiry = _variantUsesExpiry(pickedVariantKey);

                        final startDateMs = _ymdToMs(startDateYmd);
                        final monthsForExpiry =
                            _variantIsRecorded(pickedVariantKey)
                            ? durationMonths
                            : expiryMonths;
                        final expiryBaseMs =
                            _variantIsFlexible(pickedVariantKey)
                            ? startDateMs
                            : paidAtMs;
                        final expiresAt = usesExpiry
                            ? _addMonthsToMs(expiryBaseMs, monthsForExpiry)
                            : 0;

                        setD(() => isSaving = true);

                        try {
                          final dayKey = paidDateYmd;
                          final dup = await _isDuplicatePayment(
                            uid: pickedUid!,
                            courseKey: pickedCourseKey!,
                            variantKey: pickedVariantKey,
                            sessionsPaid: usesSessions ? sessionsPaid : 0,
                            durationMonths: _variantIsRecorded(pickedVariantKey)
                                ? durationMonths
                                : 0,
                            amount: fee,
                            dayKey: dayKey,
                          );
                          if (dup) {
                            setD(() => isSaving = false);
                            _toast('Duplicate payment blocked ✅');
                            return;
                          }

                          final newRef = _paymentsRef.push();
                          final paymentId = newRef.key!;

                          final courseCode = (pickedCourse['course_code'] ?? '')
                              .toString();
                          final courseTitle = (pickedCourse['title'] ?? '')
                              .toString();
                          final learnerName =
                              '${(pickedLearner['first_name'] ?? '')} ${(pickedLearner['last_name'] ?? '')}'
                                  .trim();
                          final learnerSerial = (pickedLearner['serial'] ?? '')
                              .toString();

                          final remind = usesReminder
                              ? (remindBeforeSession <= 0
                                    ? sessionsPaid
                                    : remindBeforeSession)
                              : 0;

                          final monthKey = paidDateYmd.substring(0, 7);

                          await newRef.set({
                            'uid': pickedUid,
                            'courseKey': pickedCourseKey,
                            'course_id': pickedCourseId ?? '',
                            'course_code': courseCode,
                            'course_title': courseTitle,
                            'variantKey': pickedVariantKey,
                            'variantLabel': _variantLabel(
                              variantKey: pickedVariantKey,
                              studyMode: pickedStudyMode,
                            ),
                            'studyMode': pickedStudyMode,
                            'studyModeLabel': pickedStudyModeLabel,
                            'sessionsPaid': usesSessions ? sessionsPaid : null,
                            'remindBeforeSession': usesReminder ? remind : null,
                            'durationMonths':
                                _variantIsRecorded(pickedVariantKey)
                                ? durationMonths
                                : null,
                            'expiryMonths': _variantIsFlexible(pickedVariantKey)
                                ? expiryMonths
                                : null,
                            'expiresAt': usesExpiry ? expiresAt : null,
                            'amount': fee,
                            'method': method,
                            'teacherId': usesTeacher
                                ? (selectedTeacherUid ?? '')
                                : null,
                            'teacherName': usesTeacher
                                ? (selectedTeacherName ?? '')
                                : null,
                            'startDate': usesStartDate ? startDateYmd : null,
                            'notes': notesC.text.trim(),
                            'paidAt': paidAtMs,
                            'createdAt': ServerValue.timestamp,
                            'learner_name': learnerName,
                            'learner_serial': learnerSerial,
                            'dayKey': dayKey,
                            'monthKey': monthKey,
                          });

                          await _rebuildLearnerSummaryFromPayments(
                            uid: pickedUid!,
                            courseKey: pickedCourseKey!,
                          );

                          if (usesExpiry) {
                            await _writeVariantAccess(
                              uid: pickedUid!,
                              courseKey: pickedCourseKey!,
                              variantKey: pickedVariantKey,
                              expiresAt: expiresAt,
                              months: monthsForExpiry,
                              paymentId: paymentId,
                            );
                          }

                          await _sendPaymentReceiptMail(
                            learnerUid: pickedUid!,
                            learnerName: learnerName.isEmpty
                                ? 'Learner'
                                : learnerName,
                            courseTitle: courseTitle,
                            amount: fee,
                            sessionsPaid: usesSessions ? sessionsPaid : 0,
                            paidDateYmd: paidDateYmd,
                            variantKey: pickedVariantKey,
                            durationMonths: _variantIsRecorded(pickedVariantKey)
                                ? durationMonths
                                : 0,
                            expiresAt: expiresAt,
                          );

                          if (context.mounted) Navigator.pop(context);
                          _toast('Payment saved ✅');
                        } catch (e) {
                          setD(() => isSaving = false);
                          _toast(toHumanError(e));
                        }
                      },
                child: Text(isSaving ? 'Saving…' : 'Save'),
              ),
            ],
          );
        },
      ),
    );
  }

  // ----------------- EDIT / DELETE -----------------

  Future<void> _openEditPaymentDialog(Map<String, dynamic> p) async {
    final paymentId = (p['paymentId'] ?? '').toString();
    final learnerName = (p['learner_name'] ?? '').toString().trim();
    final titleName = learnerName.isEmpty ? 'Edit' : 'Edit: $learnerName';
    if (paymentId.isEmpty) return;

    final oldUid = (p['uid'] ?? '').toString().trim();
    final oldCourseKey = (p['courseKey'] ?? '').toString().trim();

    final variantKey = _normalizeVariantKey((p['variantKey'] ?? '').toString());
    int sessionsPaid = _asInt(p['sessionsPaid']);
    if (sessionsPaid <= 0 && _variantUsesSessions(variantKey)) sessionsPaid = 8;

    int remindBeforeSession = _asInt(p['remindBeforeSession']);
    if (_variantUsesReminder(variantKey) && remindBeforeSession <= 0) {
      remindBeforeSession = (sessionsPaid > 0 ? sessionsPaid : 1);
    }

    int expiryMonths = _asInt(p['expiryMonths']);
    int durationMonths = _asInt(p['durationMonths']);
    final existingExpiresAt = _asInt(p['expiresAt']);
    final paidDateSeed = _fmtDateFromMs(p['paidAt']);
    final paidMsSeed = _ymdToMs(
      paidDateSeed.isEmpty ? _todayYmd() : paidDateSeed,
    );

    if (_variantIsFlexible(variantKey) && expiryMonths <= 0) {
      final inferred = _monthsBetweenMs(paidMsSeed, existingExpiresAt);
      expiryMonths = inferred > 0 ? inferred : 1;
    }
    if (_variantIsRecorded(variantKey) && durationMonths <= 0) {
      final inferred = _monthsBetweenMs(paidMsSeed, existingExpiresAt);
      durationMonths = inferred > 0 ? inferred : 1;
    }

    String method = (p['method'] ?? _methods.first).toString();

    final amountC = TextEditingController(text: _asInt(p['amount']).toString());
    final notesC = TextEditingController(text: (p['notes'] ?? '').toString());

    String paidDateYmd = paidDateSeed;
    if (paidDateYmd.trim().isEmpty) paidDateYmd = _todayYmd();

    String startDateYmd = (p['startDate'] ?? '').toString();
    if (startDateYmd.trim().isEmpty) startDateYmd = _todayYmd();

    String? selectedTeacherUid = (p['teacherId'] ?? '').toString().trim();
    if (selectedTeacherUid.isEmpty) selectedTeacherUid = null;
    String? selectedTeacherName = (p['teacherName'] ?? '').toString().trim();
    if (selectedTeacherName.isEmpty) selectedTeacherName = null;

    bool isSaving = false;

    await showDialog<void>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setD) {
          final usesTeacher = _variantUsesTeacher(variantKey);
          final usesSessions = _variantUsesSessions(variantKey);
          final usesReminder = _variantUsesReminder(variantKey);
          final usesStartDate = _variantUsesStartDate(variantKey);
          final usesExpiry = _variantUsesExpiry(variantKey);
          final isRecorded = _variantIsRecorded(variantKey);
          final previewExpiryBaseMs = _variantIsFlexible(variantKey)
              ? _ymdToMs(startDateYmd)
              : _ymdToMs(paidDateYmd);

          final previewExpiryMs = usesExpiry
              ? _addMonthsToMs(
                  previewExpiryBaseMs,
                  isRecorded ? durationMonths : expiryMonths,
                )
              : 0;
          final previewExpiryYmd = usesExpiry
              ? _fmtDateFromMs(previewExpiryMs)
              : '';

          return AlertDialog(
            title: Text(titleName),
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
                        if (usesStartDate) ...[
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
                      ],
                    ),
                    const SizedBox(height: 12),

                    if (usesTeacher) ...[
                      _TeacherDropdownFromUsers(
                        usersRef: _usersRef,
                        valueUid: selectedTeacherUid,
                        fallbackName: selectedTeacherName,
                        onChanged: (uid, name) => setD(() {
                          selectedTeacherUid = uid;
                          selectedTeacherName = name;
                        }),
                      ),
                      const SizedBox(height: 12),
                    ],

                    if (usesSessions) ...[
                      _NumberPickerRow(
                        label: 'Sessions paid',
                        value: sessionsPaid,
                        min: 1,
                        max: 60,
                        onChanged: (v) {
                          sessionsPaid = v;
                          if (usesReminder &&
                              remindBeforeSession > sessionsPaid) {
                            remindBeforeSession = sessionsPaid;
                          }
                          setD(() {});
                        },
                      ),
                      const SizedBox(height: 10),
                    ],

                    if (usesReminder) ...[
                      _NumberPickerRow(
                        label: 'Reminder when left',
                        value: remindBeforeSession,
                        min: 1,
                        max: (sessionsPaid > 0 ? sessionsPaid : 1),
                        onChanged: (v) => setD(() => remindBeforeSession = v),
                      ),
                      const SizedBox(height: 10),
                    ],

                    if (_variantIsFlexible(variantKey)) ...[
                      _NumberPickerRow(
                        label: 'Expires in months',
                        value: expiryMonths,
                        min: 1,
                        max: 12,
                        onChanged: (v) => setD(() => expiryMonths = v),
                      ),
                      const SizedBox(height: 10),
                      _InfoLine(
                        label: 'Expires on',
                        value: previewExpiryYmd.isEmpty
                            ? '—'
                            : previewExpiryYmd,
                      ),
                      const SizedBox(height: 10),
                    ],

                    if (_variantIsRecorded(variantKey)) ...[
                      _NumberPickerRow(
                        label: 'Duration months',
                        value: durationMonths,
                        min: 1,
                        max: 12,
                        onChanged: (v) => setD(() => durationMonths = v),
                      ),
                      const SizedBox(height: 10),
                      _InfoLine(
                        label: 'Expires on',
                        value: previewExpiryYmd.isEmpty
                            ? '—'
                            : previewExpiryYmd,
                      ),
                      const SizedBox(height: 10),
                    ],

                    DropdownButtonFormField<String>(
                      initialValue: method,
                      decoration: const InputDecoration(labelText: 'Method'),
                      items: _methods
                          .map(
                            (m) => DropdownMenuItem(value: m, child: Text(m)),
                          )
                          .toList(),
                      onChanged: (v) => setD(() => method = v ?? method),
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: amountC,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Fee'),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: notesC,
                      maxLines: 2,
                      decoration: const InputDecoration(labelText: 'Notes'),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: isSaving
                    ? null
                    : () async {
                        final fee = int.tryParse(amountC.text.trim()) ?? 0;
                        if (fee <= 0) {
                          _toast('Fee must be > 0');
                          return;
                        }

                        final paidAtMs = _ymdToMs(paidDateYmd);
                        if (paidAtMs <= 0) {
                          _toast('Invalid paid date.');
                          return;
                        }

                        setD(() => isSaving = true);

                        try {
                          final monthKey = paidDateYmd.substring(0, 7);
                          final usesExpiry = _variantUsesExpiry(variantKey);
                          final startDateMs = _ymdToMs(startDateYmd);
                          final monthsForExpiry = _variantIsRecorded(variantKey)
                              ? durationMonths
                              : expiryMonths;
                          final expiryBaseMs = _variantIsFlexible(variantKey)
                              ? startDateMs
                              : paidAtMs;
                          final expiresAt = usesExpiry
                              ? _addMonthsToMs(expiryBaseMs, monthsForExpiry)
                              : 0;

                          await _paymentsRef.child(paymentId).update({
                            'sessionsPaid': _variantUsesSessions(variantKey)
                                ? sessionsPaid
                                : null,
                            'remindBeforeSession':
                                _variantUsesReminder(variantKey)
                                ? remindBeforeSession
                                : null,
                            'method': method,
                            'amount': fee,
                            'teacherId': _variantUsesTeacher(variantKey)
                                ? (selectedTeacherUid ?? '')
                                : null,
                            'teacherName': _variantUsesTeacher(variantKey)
                                ? (selectedTeacherName ?? '')
                                : null,
                            'startDate': _variantUsesStartDate(variantKey)
                                ? startDateYmd
                                : null,
                            'expiryMonths': _variantIsFlexible(variantKey)
                                ? expiryMonths
                                : null,
                            'durationMonths': _variantIsRecorded(variantKey)
                                ? durationMonths
                                : null,
                            'expiresAt': usesExpiry ? expiresAt : null,
                            'notes': notesC.text.trim(),
                            'paidAt': paidAtMs,
                            'dayKey': paidDateYmd,
                            'monthKey': monthKey,
                            'updatedAt': ServerValue.timestamp,
                          });

                          if (oldUid.isNotEmpty && oldCourseKey.isNotEmpty) {
                            await _rebuildLearnerSummaryFromPayments(
                              uid: oldUid,
                              courseKey: oldCourseKey,
                            );
                            if (_variantUsesExpiry(variantKey)) {
                              await _rebuildVariantAccessFromPayments(
                                uid: oldUid,
                                courseKey: oldCourseKey,
                                variantKey: variantKey,
                              );
                            }
                          }

                          if (context.mounted) Navigator.pop(context);
                          _toast('Updated ✅');
                        } catch (e) {
                          setD(() => isSaving = false);
                          _toast(toHumanError(e));
                        }
                      },
                child: Text(isSaving ? 'Saving…' : 'Save'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _deletePayment(Map<String, dynamic> p) async {
    final paymentId = (p['paymentId'] ?? '').toString();
    if (paymentId.isEmpty) return;

    final ok =
        await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Delete payment?'),
            content: const Text(
              'This will delete the payment record and rebuild learner payment data.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
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
      await _paymentsRef.child(paymentId).remove();

      final uid = (p['uid'] ?? '').toString().trim();
      final courseKey = (p['courseKey'] ?? '').toString().trim();
      final variantKey = _normalizeVariantKey(
        (p['variantKey'] ?? '').toString(),
      );

      if (uid.isNotEmpty && courseKey.isNotEmpty) {
        await _rebuildLearnerSummaryFromPayments(
          uid: uid,
          courseKey: courseKey,
        );
        if (_variantUsesExpiry(variantKey)) {
          await _rebuildVariantAccessFromPayments(
            uid: uid,
            courseKey: courseKey,
            variantKey: variantKey,
          );
        }
      }

      setState(() => _selectedPaymentIds.remove(paymentId));
      _toast('Deleted ✅');
    } catch (e) {
      _toast(toHumanError(e));
    }
  }
}

// ------------------ Compact UI pieces ------------------

class _Pill extends StatelessWidget {
  const _Pill({
    required this.icon,
    required this.text,
    this.strong = false,
    this.color,
    this.borderColor,
  });

  final IconData icon;
  final String text;
  final bool strong;
  final Color? color;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: color ?? AdminPaymentsScreen.appBg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: borderColor ?? Colors.black.withValues(alpha: 0.06),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 16,
            color: AdminPaymentsScreen.primaryBlue.withValues(alpha: 0.85),
          ),
          const SizedBox(width: 8),
          Text(
            text,
            style: TextStyle(
              fontWeight: strong ? FontWeight.w900 : FontWeight.w800,
              color: AdminPaymentsScreen.primaryBlue.withValues(alpha: 0.92),
              fontSize: 12.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _SmallDropdown<T> extends StatelessWidget {
  const _SmallDropdown({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final String label;
  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: AdminPaymentsScreen.appBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.black.withValues(alpha: 0.06)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$label:',
            style: TextStyle(
              fontWeight: FontWeight.w900,
              color: AdminPaymentsScreen.primaryBlue.withValues(alpha: 0.85),
              fontSize: 12,
            ),
          ),
          const SizedBox(width: 8),
          DropdownButtonHideUnderline(
            child: DropdownButton<T>(
              value: value,
              items: items,
              onChanged: onChanged,
              style: TextStyle(
                fontWeight: FontWeight.w900,
                color: AdminPaymentsScreen.primaryBlue.withValues(alpha: 0.92),
                fontSize: 12.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ------------------ Table header ------------------

class _TableHeaderRow extends StatelessWidget {
  const _TableHeaderRow();

  @override
  Widget build(BuildContext context) {
    TextStyle s(bool strong) => TextStyle(
      fontWeight: strong ? FontWeight.w900 : FontWeight.w800,
      color: AdminPaymentsScreen.primaryBlue.withValues(alpha: 0.9),
      fontSize: 12,
    );

    Widget h(String t, {required int flex, bool strong = false}) {
      return Expanded(
        flex: flex,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Text(
            t,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: s(strong),
          ),
        ),
      );
    }

    return Row(
      children: [
        const SizedBox(width: 34),
        h('#', flex: 1, strong: true),
        h('Paid', flex: 2),
        h('Learner', flex: 3, strong: true),
        h('Variant', flex: 2),
        h('Amount', flex: 2),
        h('Plan', flex: 2),
        h('Teacher', flex: 3),
        h('Class', flex: 3),
        h('Start/Expire', flex: 2),
        h('Notes', flex: 4),
        const SizedBox(width: 40),
      ],
    );
  }
}

// ------------------ Teacher dropdown from /users (role=teacher) ------------------

class _TeacherDropdownFromUsers extends StatelessWidget {
  const _TeacherDropdownFromUsers({
    required this.usersRef,
    required this.valueUid,
    required this.onChanged,
    this.fallbackName,
  });

  final DatabaseReference usersRef;
  final String? valueUid;
  final String? fallbackName;
  final void Function(String? teacherUid, String? teacherName) onChanged;

  bool _isTeacherRole(dynamic role) {
    final r = (role ?? '').toString().trim().toLowerCase();
    return r == 'teacher' || r == 'teachers' || r == 'teacher(s)';
  }

  String _labelFor(String uid, Map<String, dynamic> m) {
    final first = (m['first_name'] ?? m['firstName'] ?? '').toString().trim();
    final last = (m['last_name'] ?? m['lastName'] ?? '').toString().trim();
    final full = '$first $last'.trim();
    if (full.isNotEmpty) return full;

    final name = (m['name'] ?? m['full_name'] ?? m['fullName'] ?? '')
        .toString()
        .trim();
    if (name.isNotEmpty) return name;

    final email = (m['email'] ?? '').toString().trim();
    if (email.isNotEmpty) return email;

    return uid;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<DataSnapshot>(
      future: usersRef.get(),
      builder: (context, snap) {
        final v = snap.data?.value;
        final teachers = <Map<String, String>>[];

        if (v is Map) {
          v.forEach((k, val) {
            if (val is Map) {
              final m = val.map((kk, vv) => MapEntry(kk.toString(), vv));
              if (!_isTeacherRole(m['role'])) return;

              final uid = k.toString();
              final name = _labelFor(uid, m.cast<String, dynamic>());
              teachers.add({'uid': uid, 'name': name});
            }
          });
        }

        teachers.sort((a, b) => (a['name'] ?? '').compareTo(b['name'] ?? ''));

        final uidSet = teachers.map((t) => t['uid'] ?? '').toSet();

        String? effectiveUid = (valueUid ?? '').trim();
        if (effectiveUid.isEmpty || !uidSet.contains(effectiveUid)) {
          effectiveUid = null;
        }

        return DropdownButtonFormField<String>(
          initialValue: effectiveUid,
          decoration: const InputDecoration(labelText: 'Teacher'),
          items: [
            const DropdownMenuItem<String>(
              value: null,
              child: Text('— Select teacher —'),
            ),
            ...teachers.map((t) {
              final uid = t['uid'] ?? '';
              final name = t['name'] ?? uid;
              return DropdownMenuItem<String>(
                value: uid,
                child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
              );
            }),
          ],
          onChanged: (uid) {
            if (uid == null) {
              onChanged(null, null);
              return;
            }
            final found = teachers.firstWhere(
              (t) => t['uid'] == uid,
              orElse: () => {'uid': uid, 'name': uid},
            );
            onChanged(uid, found['name'] ?? uid);
          },
        );
      },
    );
  }
}

// ------------------ Learner autocomplete ------------------

class _LearnerAutocomplete extends StatefulWidget {
  const _LearnerAutocomplete({required this.usersRef, required this.onPicked});

  final DatabaseReference usersRef;
  final Future<void> Function(String uid, Map<String, dynamic> learnerMap)
  onPicked;

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

          final name = '${(m['first_name'] ?? '')} ${(m['last_name'] ?? '')}'
              .trim()
              .toLowerCase();
          final email = (m['email'] ?? '').toString().toLowerCase();
          final serial = (m['serial'] ?? '').toString().toLowerCase();

          if (name.contains(q) || email.contains(q) || serial.contains(q)) {
            out.add({'uid': uid.toString(), ...m});
          }
        }
      });
    }

    out.sort(
      (a, b) => ('${a['first_name']} ${a['last_name']}').toString().compareTo(
        '${b['first_name']} ${b['last_name']}',
      ),
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
              border: Border.all(color: Colors.black.withValues(alpha: 0.08)),
            ),
            child: ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _results.length,
              separatorBuilder: (_, _) =>
                  Divider(height: 1, color: Colors.black.withValues(alpha: 0.06)),
              itemBuilder: (context, i) {
                final r = _results[i];
                final name =
                    '${(r['first_name'] ?? '')} ${(r['last_name'] ?? '')}'
                        .trim();
                final serial = (r['serial'] ?? '').toString();
                return ListTile(
                  dense: true,
                  title: Text(
                    name,
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                  subtitle: Text(
                    serial,
                    style: TextStyle(color: Colors.black.withValues(alpha: 0.6)),
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
          color: Colors.black.withValues(alpha: 0.6),
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AdminPaymentsScreen.appBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.black.withValues(alpha: 0.06)),
      ),
      child: Row(
        children: [
          Text('$label: ', style: const TextStyle(fontWeight: FontWeight.w900)),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w800),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
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
          child: Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w900),
          ),
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
          fillColor: AdminPaymentsScreen.appBg,
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

Future<void> _sendPaymentReceiptMail({
  required String learnerUid,
  required String learnerName,
  required String courseTitle,
  required int amount,
  required int sessionsPaid,
  required String paidDateYmd,
  required String variantKey,
  required int durationMonths,
  required int expiresAt,
}) async {
  final meUid = FirebaseAuth.instance.currentUser?.uid ?? '';
  final meName = (FirebaseAuth.instance.currentUser?.email ?? 'Admin').trim();
  if (meUid.isEmpty) return;

  final db = FirebaseDatabase.instance;
  final threadsRef = db.ref('mail_threads');
  final indexRef = db.ref('mail_index');
  final stateRef = db.ref('mail_state');

  final subject = 'Payment receipt';
  final now = DateTime.now().millisecondsSinceEpoch;

  String body =
      '✅ Payment received\n'
      'Course: $courseTitle\n'
      'Amount: $amount DA\n'
      'Paid date: $paidDateYmd\n';

  final v = variantKey.trim().toLowerCase();
  if (v == 'recorded') {
    body += 'Access: $durationMonths month(s)\n';
    if (expiresAt > 0) {
      final d = DateTime.fromMillisecondsSinceEpoch(expiresAt);
      String two(int n) => n.toString().padLeft(2, '0');
      body += 'Expires: ${d.year}-${two(d.month)}-${two(d.day)}\n';
    }
  } else if (v == 'flexible') {
    body += 'Sessions: $sessionsPaid\n';
    if (expiresAt > 0) {
      final d = DateTime.fromMillisecondsSinceEpoch(expiresAt);
      String two(int n) => n.toString().padLeft(2, '0');
      body += 'Expires: ${d.year}-${two(d.month)}-${two(d.day)}\n';
    }
  } else {
    body += 'Sessions: $sessionsPaid\n';
  }

  String? threadId;

  final adminIndexSnap = await indexRef.child(meUid).get();
  final indexRaw = adminIndexSnap.value;

  if (indexRaw is Map) {
    for (final e in indexRaw.entries) {
      final tid = e.key.toString();
      final mRaw = e.value;
      if (mRaw is! Map) continue;
      final m = mRaw.map((k, v) => MapEntry(k.toString(), v));

      final peerUid = (m['peerUid'] ?? '').toString().trim();
      final subj = (m['subject'] ?? '').toString().trim();
      final deletedAt = m['deletedAt'];

      if (deletedAt != null) continue;
      if (peerUid == learnerUid && subj == subject) {
        threadId = tid;
        break;
      }
    }
  }

  if (threadId == null) {
    threadId = threadsRef.push().key!;
    await threadsRef.child(threadId).set({
      'subject': subject,
      'createdAt': now,
      'updatedAt': now,
      'lastMessage': '',
    });

    await indexRef.child(meUid).child(threadId).set({
      'subject': subject,
      'updatedAt': now,
      'lastMessage': '',
      'unreadCount': 0,
      'peerUid': learnerUid,
      'peerName': learnerName,
      'deletedAt': null,
    });

    await indexRef.child(learnerUid).child(threadId).set({
      'subject': subject,
      'updatedAt': now,
      'lastMessage': '',
      'unreadCount': 0,
      'peerUid': meUid,
      'peerName': meName.isEmpty ? 'Admin' : meName,
      'deletedAt': null,
    });
  }

  final msgsRef = db.ref('mail_messages/$threadId');
  final msgRef = msgsRef.push();
  final preview80 = body.length > 80 ? body.substring(0, 80) : body;

  await msgRef.set({
    'fromUid': meUid,
    'body': body,
    'toUids': {learnerUid: true},
    'ccUids': {},
    'bccUids': {},
    'attachments': [],
    'createdAt': now,
    'deletedFor': {},
  });

  await db.ref('mail_threads/$threadId').update({
    'updatedAt': now,
    'lastMessage': preview80,
  });

  await indexRef.child(meUid).child(threadId).update({
    'subject': subject,
    'updatedAt': now,
    'lastMessage': preview80,
    'unreadCount': 0,
    'peerUid': learnerUid,
    'peerName': learnerName,
    'deletedAt': null,
  });

  await indexRef.child(learnerUid).child(threadId).runTransaction((cur) {
    final m = (cur as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    final oldUnread = (m['unreadCount'] is num)
        ? (m['unreadCount'] as num).toInt()
        : 0;

    m['subject'] = subject;
    m['updatedAt'] = now;
    m['lastMessage'] = preview80;
    m['unreadCount'] = oldUnread + 1;
    m['peerUid'] = meUid;
    m['peerName'] = meName.isEmpty ? 'Admin' : meName;
    m['deletedAt'] = null;

    return Transaction.success(m);
  });

  await stateRef.child(meUid).child(threadId).update({'lastReadAt': now});
}
