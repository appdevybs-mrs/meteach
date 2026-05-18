import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:excel/excel.dart' hide Border;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import '../services/mail_consistency_service.dart';
import '../shared/human_error.dart';
import '../shared/app_feedback.dart';
import '../shared/admin_web_layout.dart';
import '../shared/payment_status.dart';
import '../shared/study_variant.dart';

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
  static const int _paymentsWindowSize = 3000;

  DatabaseReference get _paymentsRef => _db.ref('payments');
  DatabaseReference get _paymentPeriodsRef => _db.ref('payment_periods');
  DatabaseReference get _usersRef => _db.ref('users');
  DatabaseReference get _coursesRef => _db.ref('courses');

  String? _selectedMonthYyyyMm;
  String _selectedPaymentsView = _paymentsViewCurrent;
  String? _selectedArchiveBucketId;
  String _selectedTeacherFilter = _teacherFilterAll;
  String _selectedVariantFilter = _variantFilterAll;
  String _selectedNotesFilter = _notesFilterAll;
  final ScrollController _rowsScrollMain = ScrollController();
  final ScrollController _rowsScrollFrozen = ScrollController();
  bool _syncingRowsScroll = false;
  bool _showNameSearch = false;
  final TextEditingController _nameSearchCtrl = TextEditingController();
  String _nameSearchQuery = '';

  static const List<String> _methods = ['Cash', 'Card', 'Transfer', 'Other'];
  static const String _teacherFilterAll = '__all__';
  static const String _teacherFilterHasTeacher = '__has_teacher__';
  static const String _teacherFilterNoTeacher = '__no_teacher__';
  static const String _variantFilterAll = '__all__';
  static const String _paymentsViewCurrent = 'current';
  static const String _paymentsViewArchive = 'archive';
  static const String _legacyArchivePrefix = '__legacy_month__:';
  static const String _notesFilterAll = '__all__';
  static const String _notesFilterHasNotes = '__has_notes__';
  static const String _notesFilterNoNotes = '__no_notes__';
  static const String _teacherFilterPrefix = 'teacher:';
  static const String _variantFilterPrefix = 'variant:';

  @override
  void initState() {
    super.initState();
    _nameSearchCtrl.addListener(() {
      final q = _nameSearchCtrl.text.trim().toLowerCase();
      if (q == _nameSearchQuery) return;
      setState(() => _nameSearchQuery = q);
    });
    _rowsScrollMain.addListener(() {
      if (_syncingRowsScroll || !_rowsScrollFrozen.hasClients) return;
      _syncingRowsScroll = true;
      _rowsScrollFrozen.jumpTo(
        _rowsScrollMain.offset.clamp(
          _rowsScrollFrozen.position.minScrollExtent,
          _rowsScrollFrozen.position.maxScrollExtent,
        ),
      );
      _syncingRowsScroll = false;
    });
    _rowsScrollFrozen.addListener(() {
      if (_syncingRowsScroll || !_rowsScrollMain.hasClients) return;
      _syncingRowsScroll = true;
      _rowsScrollMain.jumpTo(
        _rowsScrollFrozen.offset.clamp(
          _rowsScrollMain.position.minScrollExtent,
          _rowsScrollMain.position.maxScrollExtent,
        ),
      );
      _syncingRowsScroll = false;
    });
  }

  @override
  void dispose() {
    _nameSearchCtrl.dispose();
    _rowsScrollMain.dispose();
    _rowsScrollFrozen.dispose();
    super.dispose();
  }

  String _learnerNameFromPayment(Map<String, dynamic> p) {
    final n1 = (p['learner_name'] ?? '').toString().trim();
    if (n1.isNotEmpty) return n1;
    final n2 = (p['learnerName'] ?? '').toString().trim();
    if (n2.isNotEmpty) return n2;
    final n3 = (p['name'] ?? '').toString().trim();
    if (n3.isNotEmpty) return n3;
    return '';
  }

  void _toggleNameSearch() {
    setState(() {
      _showNameSearch = !_showNameSearch;
      if (!_showNameSearch) {
        _nameSearchCtrl.clear();
      }
    });
  }

  void _toast(String msg) {
    if (!mounted) return;
    AppToast.fromSnackBar(
      context,
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
      if (m == 'online') return 'Private Online';
      if (m == 'inclass') return 'Private In-Class';
      return 'Private';
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

  static bool _variantUsesLegacySessionFallback(String variantKey) {
    final v = _normalizeVariantKey(variantKey);
    return v == 'inclass' || v == 'private';
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

  static String _teacherLabelFrom(Map<String, dynamic> row) {
    return _readFirstNonEmpty(row, ['teacherName', 'teacher_name', 'teacher']);
  }

  static bool _isPseudoTeacherLabel(String teacherName) {
    final t = teacherName.trim().toLowerCase();
    return t == 'waiting' || t == 'service';
  }

  static bool _isServiceTeacherLabel(String teacherName) {
    return teacherName.trim().toLowerCase() == 'service';
  }

  static bool _isServicePayment(Map<String, dynamic> row) {
    return _isServiceTeacherLabel(_teacherLabelFrom(row));
  }

  static bool _hasAssignedTeacher(Map<String, dynamic> row) {
    final teacherId = _readFirstNonEmpty(row, [
      'teacherId',
      'teacher_id',
    ]).trim();
    if (teacherId.isNotEmpty) return true;
    final teacherName = _teacherLabelFrom(row).trim();
    if (teacherName.isEmpty) return false;
    return !_isPseudoTeacherLabel(teacherName);
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

  String _previousDayYmd(String ymd) {
    final ms = _ymdToMs(ymd);
    if (ms <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(
      ms,
    ).subtract(const Duration(days: 1));
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  String _defaultPaymentPeriodLabel(String startDateYmd) {
    return 'From $startDateYmd';
  }

  String _paymentPeriodId(Map<String, dynamic> p) {
    return (p['periodId'] ?? '').toString().trim();
  }

  String _paymentArchiveBucketId(Map<String, dynamic> p) {
    final periodId = _paymentPeriodId(p);
    if (periodId.isNotEmpty) return periodId;
    final monthKey = _monthOfPayment(p);
    if (monthKey.isNotEmpty) return '$_legacyArchivePrefix$monthKey';
    return '${_legacyArchivePrefix}unknown';
  }

  String _legacyArchiveLabel(String monthKey) {
    return monthKey.isEmpty ? 'Legacy payments' : 'Legacy $monthKey';
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

  Future<void> _rebuildLearnerSummaryFromPayments({
    required String uid,
    required String courseKey,
  }) async {
    final courseSnap = await _usersRef
        .child(uid)
        .child('courses')
        .child(courseKey)
        .get();
    final courseMap = courseSnap.value is Map
        ? (courseSnap.value as Map)
              .map((k, v) => MapEntry(k.toString(), v))
              .cast<String, dynamic>()
        : <String, dynamic>{};
    final expectedVariant = normalizeVariantKey(
      (courseMap['variantKey'] ?? courseMap['variant'] ?? '').toString(),
      fallback: '',
    );
    final expectedCourseId = (courseMap['id'] ?? '').toString().trim();

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
    int lastExpiresAt = 0;
    int lastExpiryMonths = 0;
    int lastDurationMonths = 0;

    if (v is Map) {
      for (final entry in v.entries) {
        final raw = entry.value;
        if (raw is! Map) continue;
        final m = raw.map((k, v) => MapEntry(k.toString(), v));

        final payCourseKey = (m['courseKey'] ?? '').toString().trim();
        final payCourseId = (m['course_id'] ?? m['courseId'] ?? '')
            .toString()
            .trim();
        final matchesCourse =
            payCourseKey == courseKey ||
            (expectedCourseId.isNotEmpty && payCourseId == expectedCourseId);
        if (!matchesCourse) continue;
        if (_isServicePayment(m.cast<String, dynamic>())) continue;

        final amount = _asInt(m['amount']);
        final rawVariant = (m['variantKey'] ?? m['deliveryKey'] ?? m['variant'])
            .toString();
        final payVariant = _normalizeVariantKey(rawVariant);
        if (expectedVariant.isNotEmpty &&
            payVariant.isNotEmpty &&
            payVariant != expectedVariant) {
          continue;
        }
        final effectiveVariant = payVariant.isNotEmpty
            ? payVariant
            : expectedVariant;

        var sp = _asInt(m['sessionsPaid']);
        if (sp <= 0 &&
            amount > 0 &&
            _variantUsesLegacySessionFallback(effectiveVariant)) {
          sp = 8;
        }
        final paidAt = _asInt(m['paidAt']);
        final method = (m['method'] ?? '').toString();
        final remind = _asInt(m['remindBeforeSession']);

        totalPaid += amount;
        if (_variantUsesSessions(effectiveVariant)) {
          sessionsTotal += sp;
        }

        if (paidAt >= lastPaidAt) {
          lastPaidAt = paidAt;
          lastPaymentId = entry.key.toString();
          lastMethod = method;
          lastAmount = amount;
          lastRemind = remind;
          lastVariantKey = effectiveVariant;
          lastExpiresAt = _asInt(m['expiresAt']);
          lastExpiryMonths = _asInt(m['expiryMonths']);
          lastDurationMonths = _asInt(m['durationMonths']);
        }
      }
    }

    int remindBeforeSession = 0;
    if (_variantUsesReminder(lastVariantKey)) {
      remindBeforeSession = normalizeReminderForSessions(
        sessionsPaidTotal: sessionsTotal,
        remindBeforeSession: (lastRemind > 0)
            ? lastRemind
            : _asInt(oldSum['remindBeforeSession']),
      );
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
      'expiresAt': _variantUsesExpiry(lastVariantKey) ? lastExpiresAt : null,
      'expiryMonths': _variantIsFlexible(lastVariantKey)
          ? lastExpiryMonths
          : null,
      'durationMonths': _variantIsRecorded(lastVariantKey)
          ? lastDurationMonths
          : null,
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

  String _timestampTag() {
    final d = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}${two(d.month)}${two(d.day)}_${two(d.hour)}${two(d.minute)}${two(d.second)}';
  }

  String _safeFilePart(String raw) {
    final s = raw.trim().replaceAll(RegExp(r'[^a-zA-Z0-9_-]+'), '_');
    return s.isEmpty ? 'all' : s;
  }

  String _monthOfPayment(Map<String, dynamic> p) {
    final byPaidAt = _fmtMonthFromMs(p['paidAt']);
    if (byPaidAt.isNotEmpty) return byPaidAt;
    final mk = (p['monthKey'] ?? '').toString().trim();
    return mk;
  }

  int _effectivePaidAtMs(Map<String, dynamic> p) {
    final paidAt = _asInt(p['paidAt']);
    if (paidAt > 0) return paidAt;

    final dayKey = (p['dayKey'] ?? '').toString().trim();
    if (dayKey.length >= 10) {
      final parsed = _ymdToMs(dayKey.substring(0, 10));
      if (parsed > 0) return parsed;
    }

    return 0;
  }

  String _monthKeyForSorting(Map<String, dynamic> p) {
    final byMonth = _monthOfPayment(p);
    if (byMonth.isNotEmpty) return byMonth;

    final fromDayKey = (p['dayKey'] ?? '').toString().trim();
    if (fromDayKey.length >= 7) return fromDayKey.substring(0, 7);

    final paidAt = _effectivePaidAtMs(p);
    if (paidAt > 0) return _fmtMonthFromMs(paidAt);

    return '0000-00';
  }

  List<Map<String, dynamic>> _applyExportFilters({
    required List<Map<String, dynamic>> all,
    required String? month,
    required String? learnerUid,
  }) {
    return all.where((p) {
      if ((month ?? '').isNotEmpty && _monthOfPayment(p) != month) {
        return false;
      }
      if ((learnerUid ?? '').isNotEmpty) {
        final uid = (p['uid'] ?? '').toString().trim();
        if (uid != learnerUid) return false;
      }
      return true;
    }).toList();
  }

  Future<String?> _defaultDownloadsDirectoryPath() async {
    try {
      if (Platform.isAndroid) {
        const androidDownloads = '/storage/emulated/0/Download';
        final dir = Directory(androidDownloads);
        if (await dir.exists()) return dir.path;
      }

      if (Platform.isLinux || Platform.isMacOS) {
        final home = Platform.environment['HOME'] ?? '';
        if (home.isNotEmpty) {
          final d = Directory('$home/Downloads');
          if (await d.exists()) return d.path;
        }
      }

      if (Platform.isWindows) {
        final profile = Platform.environment['USERPROFILE'] ?? '';
        if (profile.isNotEmpty) {
          final d = Directory('$profile\\Downloads');
          if (await d.exists()) return d.path;
        }
      }
    } catch (_) {}

    try {
      final fallback = await getApplicationDocumentsDirectory();
      return fallback.path;
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List> _buildExcelBytes(List<Map<String, dynamic>> rows) async {
    final sorted = [...rows]
      ..sort((a, b) => _asInt(b['paidAt']).compareTo(_asInt(a['paidAt'])));

    final excel = Excel.createExcel();
    final defaultName = excel.getDefaultSheet();
    if (defaultName != null && excel.sheets.containsKey(defaultName)) {
      excel.rename(defaultName, 'Payments');
    }
    final sheet = excel['Payments'];

    sheet.appendRow([
      TextCellValue('No'),
      TextCellValue('Paid Date'),
      TextCellValue('Learner'),
      TextCellValue('Serial'),
      TextCellValue('Variant'),
      TextCellValue('Amount'),
      TextCellValue('Sessions/Months'),
      TextCellValue('Teacher'),
      TextCellValue('Course'),
      TextCellValue('Start/Expiry'),
      TextCellValue('Method'),
      TextCellValue('Notes'),
      TextCellValue('Payment ID'),
    ]);

    for (int i = 0; i < sorted.length; i++) {
      final p = sorted[i];
      final paidDate = _fmtDateFromMs(p['paidAt']);
      final learnerName = (p['learner_name'] ?? '').toString().trim();
      final serial = (p['learner_serial'] ?? '').toString().trim();
      final variantText = _variantLabel(
        variantKey: (p['variantKey'] ?? '').toString(),
        studyMode: (p['studyMode'] ?? '').toString(),
      );
      final detail = _variantIsRecorded((p['variantKey'] ?? '').toString())
          ? 'Months ${_asInt(p['durationMonths'])}'
          : _variantUsesSessions((p['variantKey'] ?? '').toString())
          ? 'Sessions ${_asInt(p['sessionsPaid'])}'
          : '—';
      final teacher = (p['teacherName'] ?? '').toString().trim();
      final courseTitle = (p['course_title'] ?? '').toString().trim();
      final startDate = (p['startDate'] ?? '').toString().trim();
      final expiresAt = _fmtDateFromMs(p['expiresAt']);
      final startOrExpiry = startDate.isNotEmpty
          ? startDate
          : (expiresAt.isNotEmpty ? expiresAt : '');
      final method = (p['method'] ?? '').toString().trim();
      final notes = (p['notes'] ?? '').toString().trim();
      final pid = (p['paymentId'] ?? '').toString().trim();

      sheet.appendRow([
        IntCellValue(i + 1),
        TextCellValue(paidDate),
        TextCellValue(learnerName),
        TextCellValue(serial),
        TextCellValue(variantText),
        IntCellValue(_asInt(p['amount'])),
        TextCellValue(detail),
        TextCellValue(teacher),
        TextCellValue(courseTitle),
        TextCellValue(startOrExpiry),
        TextCellValue(method),
        TextCellValue(notes),
        TextCellValue(pid),
      ]);
    }

    final bytes = excel.encode();
    if (bytes == null) {
      throw Exception('Failed to encode Excel file');
    }
    return Uint8List.fromList(bytes);
  }

  Future<Uint8List> _buildPdfBytes({
    required List<Map<String, dynamic>> rows,
    required String month,
    required String learner,
  }) async {
    final sorted = [...rows]
      ..sort((a, b) => _asInt(b['paidAt']).compareTo(_asInt(a['paidAt'])));

    final doc = pw.Document();
    final tableData = <List<String>>[];

    for (final p in sorted) {
      final variantText = _variantLabel(
        variantKey: (p['variantKey'] ?? '').toString(),
        studyMode: (p['studyMode'] ?? '').toString(),
      );
      final detail = _variantIsRecorded((p['variantKey'] ?? '').toString())
          ? 'M ${_asInt(p['durationMonths'])}'
          : _variantUsesSessions((p['variantKey'] ?? '').toString())
          ? 'S ${_asInt(p['sessionsPaid'])}'
          : '—';
      tableData.add([
        _fmtDateFromMs(p['paidAt']),
        (p['learner_name'] ?? '').toString(),
        variantText,
        _asInt(p['amount']).toString(),
        detail,
        (p['teacherName'] ?? '').toString(),
        (p['course_title'] ?? '').toString(),
      ]);
    }

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        build: (context) => [
          pw.Text(
            'Payments Export',
            style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 8),
          pw.Text('Month: $month'),
          pw.Text('Learner: $learner'),
          pw.Text('Rows: ${tableData.length}'),
          pw.Text('Generated: ${DateTime.now().toIso8601String()}'),
          pw.SizedBox(height: 10),
          pw.TableHelper.fromTextArray(
            headers: const [
              'Paid Date',
              'Learner',
              'Variant',
              'Amount',
              'Sessions/Months',
              'Teacher',
              'Course',
            ],
            data: tableData,
            headerStyle: pw.TextStyle(
              fontSize: 9,
              fontWeight: pw.FontWeight.bold,
            ),
            cellStyle: const pw.TextStyle(fontSize: 8),
            cellAlignment: pw.Alignment.centerLeft,
          ),
        ],
      ),
    );

    return await doc.save();
  }

  Future<Uint8List> _buildBackupJsonBytes({
    required List<Map<String, dynamic>> rows,
    required String month,
    required String learner,
  }) async {
    final payload = {
      'generatedAtMs': DateTime.now().millisecondsSinceEpoch,
      'generatedAtIso': DateTime.now().toIso8601String(),
      'filters': {'month': month, 'learner': learner, 'count': rows.length},
      'payments': rows,
    };
    final text = const JsonEncoder.withIndent('  ').convert(payload);
    return Uint8List.fromList(utf8.encode(text));
  }

  Future<void> _openExportDialog({
    required List<Map<String, dynamic>> all,
    required List<String> months,
  }) async {
    final learnersByUid = <String, String>{};
    for (final p in all) {
      final uid = (p['uid'] ?? '').toString().trim();
      if (uid.isEmpty) continue;
      final name = (p['learner_name'] ?? '').toString().trim();
      if (name.isNotEmpty) learnersByUid[uid] = name;
    }
    final learnerUids = learnersByUid.keys.toList()
      ..sort((a, b) {
        final an = (learnersByUid[a] ?? '').toLowerCase();
        final bn = (learnersByUid[b] ?? '').toLowerCase();
        return an.compareTo(bn);
      });

    String? pickedMonth = _selectedMonthYyyyMm;
    String? pickedUid;
    String exportType = 'all'; // all | backup | excel | pdf
    String saveMode = 'downloads'; // downloads | choose

    await showDialog<void>(
      context: context,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (context, setD) {
            return AlertDialog(
              title: const Text('Backup / Export Payments'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    DropdownButtonFormField<String>(
                      initialValue: exportType,
                      decoration: const InputDecoration(
                        labelText: 'What to export',
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: 'all',
                          child: Text('Backup + Excel + PDF'),
                        ),
                        DropdownMenuItem(
                          value: 'backup',
                          child: Text('Backup JSON only'),
                        ),
                        DropdownMenuItem(
                          value: 'excel',
                          child: Text('Excel only'),
                        ),
                        DropdownMenuItem(value: 'pdf', child: Text('PDF only')),
                      ],
                      onChanged: (v) => setD(() => exportType = v ?? 'all'),
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String?>(
                      initialValue: pickedMonth,
                      decoration: const InputDecoration(
                        labelText: 'Month filter',
                      ),
                      items: [
                        const DropdownMenuItem<String?>(
                          value: null,
                          child: Text('All months'),
                        ),
                        ...months.map(
                          (m) => DropdownMenuItem<String?>(
                            value: m,
                            child: Text(m),
                          ),
                        ),
                      ],
                      onChanged: (v) => setD(() => pickedMonth = v),
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String?>(
                      initialValue: pickedUid,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Learner filter',
                      ),
                      items: [
                        const DropdownMenuItem<String?>(
                          value: null,
                          child: Text('All learners'),
                        ),
                        ...learnerUids.map((uid) {
                          final name = learnersByUid[uid] ?? uid;
                          return DropdownMenuItem<String?>(
                            value: uid,
                            child: Text(name, overflow: TextOverflow.ellipsis),
                          );
                        }),
                      ],
                      onChanged: (v) => setD(() => pickedUid = v),
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      initialValue: saveMode,
                      decoration: const InputDecoration(
                        labelText: 'Where to save',
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: 'downloads',
                          child: Text('Downloads (timestamped)'),
                        ),
                        DropdownMenuItem(
                          value: 'choose',
                          child: Text('Ask me folder now'),
                        ),
                      ],
                      onChanged: (v) => setD(() => saveMode = v ?? 'downloads'),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogCtx),
                  child: const Text('Cancel'),
                ),
                FilledButton.icon(
                  icon: const Icon(Icons.download_rounded),
                  label: const Text('Export'),
                  onPressed: () async {
                    try {
                      final filtered = _applyExportFilters(
                        all: all,
                        month: pickedMonth,
                        learnerUid: pickedUid,
                      );

                      if (filtered.isEmpty) {
                        _toast('No payments match selected filters.');
                        return;
                      }

                      String? dirPath;
                      if (saveMode == 'choose') {
                        dirPath = await FilePicker.platform.getDirectoryPath(
                          dialogTitle: 'Choose folder to save exports',
                        );
                      } else {
                        dirPath = await _defaultDownloadsDirectoryPath();
                      }

                      if ((dirPath ?? '').trim().isEmpty) {
                        _toast('Export cancelled: no folder selected.');
                        return;
                      }

                      final dir = Directory(dirPath!);
                      if (!await dir.exists()) {
                        await dir.create(recursive: true);
                      }

                      final monthTag = _safeFilePart(
                        pickedMonth ?? 'all_months',
                      );
                      final learnerTag = _safeFilePart(
                        pickedUid == null
                            ? 'all_learners'
                            : (learnersByUid[pickedUid!] ?? pickedUid!),
                      );
                      final stamp = _timestampTag();
                      final prefix =
                          'payments_${monthTag}_${learnerTag}_$stamp';

                      final savedPaths = <String>[];

                      if (exportType == 'all' || exportType == 'backup') {
                        final b = await _buildBackupJsonBytes(
                          rows: filtered,
                          month: pickedMonth ?? 'all',
                          learner: pickedUid == null
                              ? 'all'
                              : (learnersByUid[pickedUid!] ?? pickedUid!),
                        );
                        final file = File('${dir.path}/$prefix.backup.json');
                        await file.writeAsBytes(b, flush: true);
                        savedPaths.add(file.path);
                      }

                      if (exportType == 'all' || exportType == 'excel') {
                        final b = await _buildExcelBytes(filtered);
                        final file = File('${dir.path}/$prefix.xlsx');
                        await file.writeAsBytes(b, flush: true);
                        savedPaths.add(file.path);
                      }

                      if (exportType == 'all' || exportType == 'pdf') {
                        final b = await _buildPdfBytes(
                          rows: filtered,
                          month: pickedMonth ?? 'all',
                          learner: pickedUid == null
                              ? 'all'
                              : (learnersByUid[pickedUid!] ?? pickedUid!),
                        );
                        final file = File('${dir.path}/$prefix.pdf');
                        await file.writeAsBytes(b, flush: true);
                        savedPaths.add(file.path);
                      }

                      if (!mounted) return;
                      if (dialogCtx.mounted &&
                          Navigator.of(dialogCtx).canPop()) {
                        Navigator.pop(dialogCtx);
                      }
                      _toast(
                        'Exported ${savedPaths.length} file(s) to ${dir.path}',
                      );
                    } catch (e) {
                      _toast(toHumanError(e, fallback: 'Export failed.'));
                    }
                  },
                ),
              ],
            );
          },
        );
      },
    );
  }

  // ---------------- UI ----------------

  Future<void> _openFreshStartDialog({
    required _PaymentPeriodRecord? activePeriod,
  }) async {
    String startDateYmd = _todayYmd();
    final labelC = TextEditingController(
      text: _defaultPaymentPeriodLabel(startDateYmd),
    );
    bool didEditLabel = false;
    bool isSaving = false;
    bool saveLocked = false;

    await showDialog<void>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setD) {
          final navigator = Navigator.of(context);
          return AlertDialog(
            title: const Text('Fresh Start'),
            content: SizedBox(
              width: 460,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _DateField(
                    label: 'Start date',
                    value: startDateYmd,
                    onTap: () async {
                      final picked = await _pickDateYmd(
                        context: context,
                        initialYmd: startDateYmd,
                        helpText: 'Pick period start date',
                      );
                      if (picked == null) return;
                      startDateYmd = picked;
                      if (!didEditLabel) {
                        labelC.text = _defaultPaymentPeriodLabel(startDateYmd);
                      }
                      setD(() {});
                    },
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: labelC,
                    decoration: const InputDecoration(
                      labelText: 'Label',
                      hintText: 'Example: From 2026-04-12',
                    ),
                    onChanged: (_) => didEditLabel = true,
                  ),
                  if (activePeriod != null) ...[
                    const SizedBox(height: 12),
                    _InfoLine(
                      label: 'Current active period',
                      value: activePeriod.displayLabel,
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: isSaving ? null : () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: isSaving
                    ? null
                    : () async {
                        if (saveLocked) return;
                        saveLocked = true;

                        final startAtMs = _ymdToMs(startDateYmd);
                        if (startAtMs <= 0) {
                          saveLocked = false;
                          _toast('Pick a valid start date.');
                          return;
                        }

                        if (activePeriod != null &&
                            startAtMs <= activePeriod.startAtMs) {
                          saveLocked = false;
                          _toast(
                            'New period must start after the current one.',
                          );
                          return;
                        }

                        final label = labelC.text.trim().isEmpty
                            ? _defaultPaymentPeriodLabel(startDateYmd)
                            : labelC.text.trim();

                        setD(() => isSaving = true);

                        try {
                          final periodsSnap = await _paymentPeriodsRef.get();
                          final rootUpdate = <String, Object?>{};

                          if (periodsSnap.value is Map) {
                            final existing = periodsSnap.value as Map;
                            existing.forEach((k, value) {
                              if (value is! Map) return;
                              final rec = value.map(
                                (kk, vv) => MapEntry(kk.toString(), vv),
                              );
                              final isActive = rec['isActive'] == true;
                              if (isActive) {
                                rootUpdate['payment_periods/${k.toString()}/isActive'] =
                                    false;
                              }
                            });
                          }

                          if (activePeriod != null) {
                            final endDate = _previousDayYmd(startDateYmd);
                            final endAtMs = _ymdToMs(endDate);
                            rootUpdate['payment_periods/${activePeriod.id}/endDate'] =
                                endDate;
                            rootUpdate['payment_periods/${activePeriod.id}/endAtMs'] =
                                endAtMs;
                            rootUpdate['payment_periods/${activePeriod.id}/updatedAt'] =
                                ServerValue.timestamp;
                          }

                          final newRef = _paymentPeriodsRef.push();
                          final periodId = newRef.key;
                          if (periodId == null || periodId.trim().isEmpty) {
                            throw Exception('Could not create payment period.');
                          }

                          rootUpdate['payment_periods/$periodId'] = {
                            'id': periodId,
                            'label': label,
                            'startDate': startDateYmd,
                            'startAtMs': startAtMs,
                            'endDate': '',
                            'endAtMs': 0,
                            'isActive': true,
                            'createdAt': ServerValue.timestamp,
                            'updatedAt': ServerValue.timestamp,
                          };

                          await _db.ref().update(rootUpdate);

                          if (!mounted) return;
                          navigator.pop();
                          setState(() {
                            _selectedPaymentsView = _paymentsViewCurrent;
                            _selectedArchiveBucketId = null;
                          });
                          _toast('Fresh start ready ✅');
                        } catch (e) {
                          saveLocked = false;
                          setD(() => isSaving = false);
                          _toast(toHumanError(e));
                        }
                      },
                child: Text(isSaving ? 'Saving…' : 'Start'),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DatabaseEvent>(
      stream: _paymentPeriodsRef.onValue,
      builder: (context, periodsSnap) {
        if (periodsSnap.hasError) {
          return const Scaffold(
            body: Center(child: Text('Error loading payment periods.')),
          );
        }

        final rawPeriods = periodsSnap.data?.snapshot.value;
        final periods = <_PaymentPeriodRecord>[];
        if (rawPeriods is Map) {
          rawPeriods.forEach((k, value) {
            if (value is! Map) return;
            final m = value.map((kk, vv) => MapEntry(kk.toString(), vv));
            periods.add(
              _PaymentPeriodRecord.fromMap(
                id: k.toString(),
                map: m.cast<String, dynamic>(),
              ),
            );
          });
        }
        periods.sort((a, b) => b.startAtMs.compareTo(a.startAtMs));

        _PaymentPeriodRecord? activePeriod;
        final closedPeriods = <_PaymentPeriodRecord>[];
        for (final period in periods) {
          if (period.isActive && activePeriod == null) {
            activePeriod = period;
          } else {
            closedPeriods.add(period);
          }
        }

        return StreamBuilder<DatabaseEvent>(
          stream: _paymentsRef
              .orderByChild('paidAt')
              .limitToLast(_paymentsWindowSize)
              .onValue,
          builder: (context, snap) {
            if (snap.hasError) {
              return const Scaffold(
                body: Center(child: Text('Error loading payments.')),
              );
            }
            if ((periodsSnap.connectionState == ConnectionState.waiting &&
                    !periodsSnap.hasData) ||
                (snap.connectionState == ConnectionState.waiting &&
                    !snap.hasData)) {
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

            all.sort((a, b) {
              final byMonth = _monthKeyForSorting(
                a,
              ).compareTo(_monthKeyForSorting(b));
              if (byMonth != 0) return byMonth;

              final byPaidAt = _effectivePaidAtMs(
                a,
              ).compareTo(_effectivePaidAtMs(b));
              if (byPaidAt != 0) return byPaidAt;

              final byCreated = _asInt(
                a['createdAt'],
              ).compareTo(_asInt(b['createdAt']));
              if (byCreated != 0) return byCreated;

              return (a['paymentId'] ?? '').toString().compareTo(
                (b['paymentId'] ?? '').toString(),
              );
            });

            final monthsSet = <String>{};
            final legacyMonthsSet = <String>{};
            for (final p in all) {
              final mm = _fmtMonthFromMs(p['paidAt']);
              if (mm.isNotEmpty) monthsSet.add(mm);
              if (_paymentPeriodId(p).isEmpty && mm.isNotEmpty) {
                legacyMonthsSet.add(mm);
              }
            }
            final months = monthsSet.toList()..sort((a, b) => b.compareTo(a));

            if (_selectedMonthYyyyMm != null &&
                !monthsSet.contains(_selectedMonthYyyyMm)) {
              _selectedMonthYyyyMm = null;
            }

            final legacyMonths = legacyMonthsSet.toList()
              ..sort((a, b) => b.compareTo(a));
            final archiveBuckets = <_ArchiveBucket>[
              ...closedPeriods.map(
                (period) =>
                    _ArchiveBucket(id: period.id, label: period.displayLabel),
              ),
              ...legacyMonths.map(
                (monthKey) => _ArchiveBucket(
                  id: '$_legacyArchivePrefix$monthKey',
                  label: _legacyArchiveLabel(monthKey),
                ),
              ),
            ];

            final archiveBucketIds = archiveBuckets.map((e) => e.id).toSet();
            if (_selectedArchiveBucketId != null &&
                !archiveBucketIds.contains(_selectedArchiveBucketId)) {
              _selectedArchiveBucketId = null;
            }
            if (_selectedPaymentsView == _paymentsViewArchive &&
                _selectedArchiveBucketId == null &&
                archiveBuckets.isNotEmpty) {
              _selectedArchiveBucketId = archiveBuckets.first.id;
            }

            final teacherFilterMap = <String, String>{};
            final variantFilterMap = <String, String>{};
            for (final p in all) {
              final teacherName = _teacherLabelFrom(p).trim();
              if (teacherName.isNotEmpty &&
                  !_isPseudoTeacherLabel(teacherName)) {
                teacherFilterMap.putIfAbsent(
                  teacherName.toLowerCase(),
                  () => teacherName,
                );
              }

              final variantKey = _normalizeVariantKey(
                (p['variantKey'] ?? p['deliveryKey'] ?? p['variant'] ?? '')
                    .toString(),
              );
              if (variantKey.isNotEmpty) {
                variantFilterMap.putIfAbsent(
                  variantKey,
                  () => _variantLabel(
                    variantKey: variantKey,
                    studyMode: (p['studyMode'] ?? '').toString(),
                  ),
                );
              }
            }

            final teacherFilterItems = teacherFilterMap.entries.toList()
              ..sort(
                (a, b) =>
                    a.value.toLowerCase().compareTo(b.value.toLowerCase()),
              );
            final variantFilterItems = variantFilterMap.entries.toList()
              ..sort(
                (a, b) =>
                    a.value.toLowerCase().compareTo(b.value.toLowerCase()),
              );

            if (_selectedTeacherFilter.startsWith(_teacherFilterPrefix)) {
              final teacherKey = _selectedTeacherFilter.substring(
                _teacherFilterPrefix.length,
              );
              if (!teacherFilterMap.containsKey(teacherKey)) {
                _selectedTeacherFilter = _teacherFilterAll;
              }
            }
            if (_selectedVariantFilter.startsWith(_variantFilterPrefix)) {
              final variantKey = _selectedVariantFilter.substring(
                _variantFilterPrefix.length,
              );
              if (!variantFilterMap.containsKey(variantKey)) {
                _selectedVariantFilter = _variantFilterAll;
              }
            }

            Iterable<Map<String, dynamic>> filtered;
            if (_selectedPaymentsView == _paymentsViewCurrent) {
              filtered = activePeriod == null
                  ? const <Map<String, dynamic>>[]
                  : all.where((p) => _paymentPeriodId(p) == activePeriod!.id);
            } else {
              final bucketId = _selectedArchiveBucketId;
              filtered = bucketId == null
                  ? const <Map<String, dynamic>>[]
                  : all.where((p) => _paymentArchiveBucketId(p) == bucketId);
            }

            if (_selectedTeacherFilter == _teacherFilterHasTeacher) {
              filtered = filtered.where(_hasAssignedTeacher);
            } else if (_selectedTeacherFilter == _teacherFilterNoTeacher) {
              filtered = filtered.where((p) => !_hasAssignedTeacher(p));
            } else if (_selectedTeacherFilter.startsWith(
              _teacherFilterPrefix,
            )) {
              final teacherKey = _selectedTeacherFilter
                  .substring(_teacherFilterPrefix.length)
                  .trim();
              filtered = filtered.where(
                (p) => _teacherLabelFrom(p).trim().toLowerCase() == teacherKey,
              );
            }

            if (_selectedVariantFilter.startsWith(_variantFilterPrefix)) {
              final variantKey = _selectedVariantFilter
                  .substring(_variantFilterPrefix.length)
                  .trim();
              filtered = filtered.where(
                (p) =>
                    _normalizeVariantKey(
                      (p['variantKey'] ??
                              p['deliveryKey'] ??
                              p['variant'] ??
                              '')
                          .toString(),
                    ) ==
                    variantKey,
              );
            }

            if (_selectedNotesFilter == _notesFilterHasNotes) {
              filtered = filtered.where(
                (p) => (p['notes'] ?? '').toString().trim().isNotEmpty,
              );
            } else if (_selectedNotesFilter == _notesFilterNoNotes) {
              filtered = filtered.where(
                (p) => (p['notes'] ?? '').toString().trim().isEmpty,
              );
            }

            if (_nameSearchQuery.isNotEmpty) {
              filtered = filtered.where((p) {
                final name = _learnerNameFromPayment(p).toLowerCase();
                final serial = (p['learner_serial'] ?? '')
                    .toString()
                    .trim()
                    .toLowerCase();
                return name.contains(_nameSearchQuery) ||
                    serial.contains(_nameSearchQuery);
              });
            }

            final visible = filtered.toList();
            final visibleDisplayNoByPaymentId = <String, int>{};
            for (int i = 0; i < visible.length; i++) {
              final paymentId = (visible[i]['paymentId'] ?? '')
                  .toString()
                  .trim();
              if (paymentId.isEmpty) continue;
              visibleDisplayNoByPaymentId[paymentId] = i + 1;
            }

            final today = _todayYmd();
            final todayTotal = _sumAmount(
              all.where((p) => (p['dayKey'] ?? '') == today),
            );
            final visibleTotal = _sumAmount(visible);
            String currentScopeLabel =
                activePeriod?.displayLabel ?? 'No active period';
            if (_selectedPaymentsView == _paymentsViewArchive) {
              currentScopeLabel = 'Archive';
              for (final bucket in archiveBuckets) {
                if (bucket.id == _selectedArchiveBucketId) {
                  currentScopeLabel = bucket.label;
                  break;
                }
              }
            }

            final todayPill = _Pill(
              icon: Icons.today_rounded,
              text: 'Today: ${_fmtMoneyDa(todayTotal)}',
              strong: true,
            );

            final emptyMessage = _selectedPaymentsView == _paymentsViewCurrent
                ? (activePeriod == null
                      ? 'No active payment period yet. Tap Fresh Start to begin.'
                      : 'No payments in the current period yet.')
                : (archiveBuckets.isEmpty
                      ? 'No archived payments yet.'
                      : 'No payments found in this archive period.');

            return Scaffold(
              backgroundColor: AdminPaymentsScreen.appBg,
              appBar: AppBar(
                backgroundColor: Colors.white,
                elevation: 0,
                surfaceTintColor: Colors.white,
                iconTheme: const IconThemeData(
                  color: AdminPaymentsScreen.primaryBlue,
                ),
                titleSpacing: _showNameSearch
                    ? 8
                    : NavigationToolbar.kMiddleSpacing,
                title: Padding(
                  padding: EdgeInsets.fromLTRB(
                    _showNameSearch ? 0 : 2,
                    4,
                    _showNameSearch ? 4 : 2,
                    4,
                  ),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    child: _showNameSearch
                        ? TextField(
                            key: const ValueKey('payments-search-field'),
                            controller: _nameSearchCtrl,
                            autofocus: true,
                            textInputAction: TextInputAction.search,
                            style: const TextStyle(
                              color: AdminPaymentsScreen.primaryBlue,
                              fontWeight: FontWeight.w800,
                            ),
                            decoration: InputDecoration(
                              isDense: true,
                              hintText: 'Search learner name or serial',
                              filled: true,
                              fillColor: const Color(0xFFF7F9FC),
                              prefixIcon: const Icon(Icons.search_rounded),
                              suffixIcon: IconButton(
                                tooltip: _nameSearchQuery.isNotEmpty
                                    ? 'Clear search'
                                    : 'Close search',
                                onPressed: _nameSearchQuery.isNotEmpty
                                    ? () => _nameSearchCtrl.clear()
                                    : _toggleNameSearch,
                                icon: Icon(
                                  _nameSearchQuery.isNotEmpty
                                      ? Icons.backspace_outlined
                                      : Icons.close_rounded,
                                ),
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          )
                        : const Text(
                            'Payments',
                            key: ValueKey('payments-title'),
                            style: TextStyle(
                              color: AdminPaymentsScreen.primaryBlue,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                  ),
                ),
                actions: _showNameSearch
                    ? const <Widget>[]
                    : [
                        IconButton(
                          tooltip: 'Search learner',
                          icon: const Icon(
                            Icons.search_rounded,
                            color: AdminPaymentsScreen.primaryBlue,
                          ),
                          onPressed: _toggleNameSearch,
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Center(child: todayPill),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          tooltip: 'Backup / Export',
                          icon: const Icon(
                            Icons.download_rounded,
                            color: AdminPaymentsScreen.primaryBlue,
                          ),
                          onPressed: () =>
                              _openExportDialog(all: all, months: months),
                        ),
                        IconButton(
                          tooltip: 'Add payment',
                          icon: const Icon(
                            Icons.add_card_rounded,
                            color: AdminPaymentsScreen.actionOrange,
                          ),
                          onPressed: () =>
                              _openAddPaymentDialog(activePeriod: activePeriod),
                        ),
                        const SizedBox(width: 6),
                      ],
              ),
              body: adminWebBodyFrame(
                context: context,
                maxWidth: 1750,
                child: Column(
                  children: [
                    Container(
                      color: Colors.white,
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            ChoiceChip(
                              label: const Text('Current'),
                              selected:
                                  _selectedPaymentsView == _paymentsViewCurrent,
                              onSelected: (_) {
                                setState(() {
                                  _selectedPaymentsView = _paymentsViewCurrent;
                                });
                              },
                            ),
                            const SizedBox(width: 8),
                            ChoiceChip(
                              label: const Text('Archive'),
                              selected:
                                  _selectedPaymentsView == _paymentsViewArchive,
                              onSelected: (_) {
                                setState(() {
                                  _selectedPaymentsView = _paymentsViewArchive;
                                  _selectedArchiveBucketId ??=
                                      archiveBuckets.isEmpty
                                      ? null
                                      : archiveBuckets.first.id;
                                });
                              },
                            ),
                            const SizedBox(width: 10),
                            FilledButton.icon(
                              onPressed: () => _openFreshStartDialog(
                                activePeriod: activePeriod,
                              ),
                              icon: const Icon(Icons.restart_alt_rounded),
                              label: const Text('Fresh Start'),
                            ),
                            const SizedBox(width: 10),
                            if (_selectedPaymentsView == _paymentsViewArchive)
                              _SmallDropdown<String?>(
                                label: 'Archive',
                                value: _selectedArchiveBucketId,
                                items: [
                                  if (archiveBuckets.isEmpty)
                                    const DropdownMenuItem<String?>(
                                      value: null,
                                      child: Text('No archive'),
                                    ),
                                  ...archiveBuckets.map(
                                    (bucket) => DropdownMenuItem<String?>(
                                      value: bucket.id,
                                      child: Text(bucket.label),
                                    ),
                                  ),
                                ],
                                onChanged: (v) => setState(() {
                                  _selectedArchiveBucketId = v;
                                }),
                              ),
                            if (_selectedPaymentsView == _paymentsViewArchive)
                              const SizedBox(width: 10),
                            _SmallDropdown<String>(
                              label: 'Teacher',
                              value: _selectedTeacherFilter,
                              items: [
                                const DropdownMenuItem<String>(
                                  value: _teacherFilterAll,
                                  child: Text('All'),
                                ),
                                const DropdownMenuItem<String>(
                                  value: _teacherFilterHasTeacher,
                                  child: Text('Has teacher'),
                                ),
                                const DropdownMenuItem<String>(
                                  value: _teacherFilterNoTeacher,
                                  child: Text('No teacher'),
                                ),
                                ...teacherFilterItems.map(
                                  (e) => DropdownMenuItem<String>(
                                    value: '$_teacherFilterPrefix${e.key}',
                                    child: Text(e.value),
                                  ),
                                ),
                              ],
                              onChanged: (v) => setState(() {
                                _selectedTeacherFilter = v ?? _teacherFilterAll;
                              }),
                            ),
                            const SizedBox(width: 10),
                            _SmallDropdown<String>(
                              label: 'Variant',
                              value: _selectedVariantFilter,
                              items: [
                                const DropdownMenuItem<String>(
                                  value: _variantFilterAll,
                                  child: Text('All'),
                                ),
                                ...variantFilterItems.map(
                                  (e) => DropdownMenuItem<String>(
                                    value: '$_variantFilterPrefix${e.key}',
                                    child: Text(e.value),
                                  ),
                                ),
                              ],
                              onChanged: (v) => setState(() {
                                _selectedVariantFilter = v ?? _variantFilterAll;
                              }),
                            ),
                            const SizedBox(width: 10),
                            _SmallDropdown<String>(
                              label: 'Notes',
                              value: _selectedNotesFilter,
                              items: const [
                                DropdownMenuItem<String>(
                                  value: _notesFilterAll,
                                  child: Text('All'),
                                ),
                                DropdownMenuItem<String>(
                                  value: _notesFilterHasNotes,
                                  child: Text('Has notes'),
                                ),
                                DropdownMenuItem<String>(
                                  value: _notesFilterNoNotes,
                                  child: Text('No notes'),
                                ),
                              ],
                              onChanged: (v) => setState(() {
                                _selectedNotesFilter = v ?? _notesFilterAll;
                              }),
                            ),
                            const SizedBox(width: 10),
                            _Pill(
                              icon:
                                  _selectedPaymentsView == _paymentsViewCurrent
                                  ? Icons.calendar_today_rounded
                                  : Icons.inventory_2_outlined,
                              text: currentScopeLabel,
                              strong: true,
                            ),
                            const SizedBox(width: 8),
                            _Pill(
                              icon: Icons.payments_outlined,
                              text: 'Visible: ${_fmtMoneyDa(visibleTotal)}',
                              strong: true,
                            ),
                            const SizedBox(width: 6),
                            IconButton(
                              tooltip: 'Clear filters',
                              onPressed: () {
                                setState(() {
                                  _selectedMonthYyyyMm = null;
                                  _selectedTeacherFilter = _teacherFilterAll;
                                  _selectedVariantFilter = _variantFilterAll;
                                  _selectedNotesFilter = _notesFilterAll;
                                  _nameSearchCtrl.clear();
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
                          final webDesktop = isWebDesktop(context);
                          final minTableWidth = isWebDesktop(context)
                              ? 1500.0
                              : 1300.0;
                          final tableWidth =
                              constraints.maxWidth < minTableWidth
                              ? minTableWidth
                              : constraints.maxWidth;

                          if (visible.isEmpty) {
                            return Center(child: Text(emptyMessage));
                          }

                          if (webDesktop) {
                            return _buildWebFrozenPaymentsTable(
                              visible: visible,
                              visibleDisplayNoByPaymentId:
                                  visibleDisplayNoByPaymentId,
                            );
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
                                      padding: EdgeInsets.fromLTRB(
                                        0,
                                        0,
                                        0,
                                        MediaQuery.of(context).padding.bottom +
                                            28,
                                      ),
                                      itemCount: visible.length,
                                      separatorBuilder: (_, _) => Divider(
                                        height: 1,
                                        color: Colors.black.withValues(
                                          alpha: 0.07,
                                        ),
                                      ),
                                      itemBuilder: (context, i) {
                                        final p = visible[i];

                                        final paymentId = (p['paymentId'] ?? '')
                                            .toString();
                                        final idx =
                                            visibleDisplayNoByPaymentId[paymentId] ??
                                            (i + 1);

                                        final paidDate = _fmtDateFromMs(
                                          p['paidAt'],
                                        );
                                        final startDate = (p['startDate'] ?? '')
                                            .toString();
                                        final expiresAt = _fmtDateFromMs(
                                          p['expiresAt'],
                                        );
                                        final learnerName =
                                            (p['learner_name'] ?? '')
                                                .toString();
                                        final amount = _asInt(p['amount']);
                                        final teacher = (p['teacherName'] ?? '')
                                            .toString();
                                        final courseTitle =
                                            (p['course_title'] ?? '')
                                                .toString();
                                        final notes = (p['notes'] ?? '')
                                            .toString();
                                        final variantText = _variantLabel(
                                          variantKey: (p['variantKey'] ?? '')
                                              .toString(),
                                          studyMode: (p['studyMode'] ?? '')
                                              .toString(),
                                        );
                                        final isServicePayment =
                                            _isServicePayment(p);

                                        final detail = isServicePayment
                                            ? 'Service'
                                            : _variantIsRecorded(
                                                (p['variantKey'] ?? '')
                                                    .toString(),
                                              )
                                            ? 'M: ${_asInt(p['durationMonths'])}'
                                            : _variantUsesSessions(
                                                (p['variantKey'] ?? '')
                                                    .toString(),
                                              )
                                            ? 'S: ${_asInt(p['sessionsPaid'])}'
                                            : '—';

                                        final baseRowBg = (i % 2 == 0)
                                            ? Colors.white
                                            : AdminPaymentsScreen.appBg
                                                  .withValues(alpha: 0.7);

                                        return InkWell(
                                          onTap: () async =>
                                              _openEditPaymentDialog(p),
                                          child: Container(
                                            color: baseRowBg,
                                            padding: const EdgeInsets.symmetric(
                                              vertical: 10,
                                              horizontal: 6,
                                            ),
                                            child: Row(
                                              children: [
                                                const SizedBox(width: 34),
                                                _cell(
                                                  '#$idx',
                                                  flex: 1,
                                                  isStrong: true,
                                                ),
                                                _cell(
                                                  paidDate.isEmpty
                                                      ? '—'
                                                      : paidDate,
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
                                                  teacher.isEmpty
                                                      ? '—'
                                                      : teacher,
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
                                                    alignment:
                                                        Alignment.centerRight,
                                                    child: PopupMenuButton<String>(
                                                      tooltip: 'Actions',
                                                      onSelected: (a) async {
                                                        if (a == 'edit') {
                                                          await _openEditPaymentDialog(
                                                            p,
                                                          );
                                                        } else if (a ==
                                                            'delete') {
                                                          await _deletePayment(
                                                            p,
                                                          );
                                                        }
                                                      },
                                                      itemBuilder: (_) =>
                                                          const [
                                                            PopupMenuItem(
                                                              value: 'edit',
                                                              child: Text(
                                                                'Edit',
                                                              ),
                                                            ),
                                                            PopupMenuDivider(),
                                                            PopupMenuItem(
                                                              value: 'delete',
                                                              child: Text(
                                                                'Delete',
                                                              ),
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
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildWebFrozenPaymentsTable({
    required List<Map<String, dynamic>> visible,
    required Map<String, int> visibleDisplayNoByPaymentId,
  }) {
    const frozenWidth = 420.0;
    const rightMinWidth = 980.0;

    Widget headCell(String text, double width, {bool strong = false}) {
      return SizedBox(
        width: width,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontWeight: strong ? FontWeight.w900 : FontWeight.w800,
              color: AdminPaymentsScreen.primaryBlue.withValues(alpha: 0.9),
              fontSize: 12,
            ),
          ),
        ),
      );
    }

    Widget rowCell(String text, double width, {bool strong = false}) {
      return SizedBox(
        width: width,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontWeight: strong ? FontWeight.w900 : FontWeight.w700,
              color: AdminPaymentsScreen.primaryBlue.withValues(
                alpha: strong ? 1 : 0.85,
              ),
              fontSize: 12.5,
            ),
          ),
        ),
      );
    }

    Widget frozenRow(Map<String, dynamic> p, int i) {
      final paymentId = (p['paymentId'] ?? '').toString();
      final idx = visibleDisplayNoByPaymentId[paymentId] ?? (i + 1);
      final paidDate = _fmtDateFromMs(p['paidAt']);
      final learnerName = (p['learner_name'] ?? '').toString();
      final baseRowBg = (i % 2 == 0)
          ? Colors.white
          : AdminPaymentsScreen.appBg.withValues(alpha: 0.7);

      return InkWell(
        onTap: () async => _openEditPaymentDialog(p),
        child: Container(
          height: 44,
          color: baseRowBg,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(
            children: [
              const SizedBox(width: 34),
              rowCell('#$idx', 52, strong: true),
              rowCell(paidDate.isEmpty ? '—' : paidDate, 126),
              rowCell(
                learnerName.isEmpty ? '—' : learnerName,
                196,
                strong: true,
              ),
            ],
          ),
        ),
      );
    }

    Widget rightRow(Map<String, dynamic> p, int i) {
      final startDate = (p['startDate'] ?? '').toString();
      final expiresAt = _fmtDateFromMs(p['expiresAt']);
      final amount = _asInt(p['amount']);
      final teacher = (p['teacherName'] ?? '').toString();
      final courseTitle = (p['course_title'] ?? '').toString();
      final notes = (p['notes'] ?? '').toString();
      final variantText = _variantLabel(
        variantKey: (p['variantKey'] ?? '').toString(),
        studyMode: (p['studyMode'] ?? '').toString(),
      );
      final detail = _variantIsRecorded((p['variantKey'] ?? '').toString())
          ? 'M: ${_asInt(p['durationMonths'])}'
          : _variantUsesSessions((p['variantKey'] ?? '').toString())
          ? 'S: ${_asInt(p['sessionsPaid'])}'
          : '—';
      final safeDetail = _isServicePayment(p) ? 'Service' : detail;
      final baseRowBg = (i % 2 == 0)
          ? Colors.white
          : AdminPaymentsScreen.appBg.withValues(alpha: 0.7);

      return InkWell(
        onTap: () async => _openEditPaymentDialog(p),
        child: Container(
          height: 44,
          color: baseRowBg,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(
            children: [
              rowCell(variantText, 126),
              rowCell('$amount', 118, strong: true),
              rowCell(safeDetail, 150),
              rowCell(teacher.isEmpty ? '—' : teacher, 160),
              rowCell(courseTitle.isEmpty ? '—' : courseTitle, 200),
              rowCell(
                startDate.isNotEmpty
                    ? startDate
                    : (expiresAt.isNotEmpty ? expiresAt : '—'),
                132,
              ),
              rowCell(notes.isEmpty ? '—' : notes, 260),
              SizedBox(
                width: 40,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: PopupMenuButton<String>(
                    tooltip: 'Actions',
                    onSelected: (a) async {
                      if (a == 'edit') {
                        await _openEditPaymentDialog(p);
                      } else if (a == 'delete') {
                        await _deletePayment(p);
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'edit', child: Text('Edit')),
                      PopupMenuDivider(),
                      PopupMenuItem(value: 'delete', child: Text('Delete')),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Row(
      children: [
        SizedBox(
          width: frozenWidth,
          child: Column(
            children: [
              Container(
                height: 44,
                color: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Row(
                  children: [
                    const SizedBox(width: 34),
                    headCell('#', 52, strong: true),
                    headCell('Paid', 126),
                    headCell('Learner', 196, strong: true),
                  ],
                ),
              ),
              Divider(height: 1, color: Colors.black.withValues(alpha: 0.07)),
              Expanded(
                child: ListView.separated(
                  controller: _rowsScrollFrozen,
                  padding: EdgeInsets.fromLTRB(
                    0,
                    0,
                    0,
                    MediaQuery.of(context).padding.bottom + 28,
                  ),
                  itemCount: visible.length,
                  separatorBuilder: (_, _) => Divider(
                    height: 1,
                    color: Colors.black.withValues(alpha: 0.07),
                  ),
                  itemBuilder: (_, i) => frozenRow(visible[i], i),
                ),
              ),
            ],
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: rightMinWidth,
              child: Column(
                children: [
                  Container(
                    height: 44,
                    color: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Row(
                      children: [
                        headCell('Variant', 126),
                        headCell('Amount', 118),
                        headCell('Plan', 150),
                        headCell('Teacher', 160),
                        headCell('Class', 200),
                        headCell('Start/Expire', 132),
                        headCell('Notes', 260),
                        const SizedBox(width: 40),
                      ],
                    ),
                  ),
                  Divider(
                    height: 1,
                    color: Colors.black.withValues(alpha: 0.07),
                  ),
                  Expanded(
                    child: ListView.separated(
                      controller: _rowsScrollMain,
                      padding: EdgeInsets.fromLTRB(
                        0,
                        0,
                        0,
                        MediaQuery.of(context).padding.bottom + 28,
                      ),
                      itemCount: visible.length,
                      separatorBuilder: (_, _) => Divider(
                        height: 1,
                        color: Colors.black.withValues(alpha: 0.07),
                      ),
                      itemBuilder: (_, i) => rightRow(visible[i], i),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
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
            color: AdminPaymentsScreen.primaryBlue.withValues(
              alpha: isStrong ? 1 : 0.85,
            ),
            fontSize: 12.5,
          ),
        ),
      ),
    );
  }

  // ----------------- ADD PAYMENT -----------------

  Future<void> _openAddPaymentDialog({
    required _PaymentPeriodRecord? activePeriod,
  }) async {
    if (activePeriod == null) {
      _toast('Start a fresh payment period first.');
      return;
    }

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

    final amountC = TextEditingController();
    final notesC = TextEditingController();

    String paidDateYmd = _todayYmd();
    String startDateYmd = _todayYmd();

    Map<String, dynamic> pickedLearner = {};
    Map<String, dynamic> pickedCourse = {};

    String? selectedTeacherUid;
    String? selectedTeacherName;

    bool sendReceipt = true;
    bool isSaving = false;
    bool saveLocked = false;

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
        remindBeforeSession = normalizeReminderForSessions(
          sessionsPaidTotal: sessionsPaid,
          remindBeforeSession: 1,
        );
      } else {
        remindBeforeSession = 0;
      }

      if (_variantIsFlexible(pickedVariantKey)) expiryMonths = 1;
      if (_variantIsRecorded(pickedVariantKey)) durationMonths = 1;

      if (!_variantUsesTeacher(pickedVariantKey)) {
        selectedTeacherUid = null;
        selectedTeacherName = null;
      }
    }

    await showDialog<void>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setD) {
          final maxSessions = _maxSessionsFromCourse(pickedCourse);
          final usesTeacher =
              _variantUsesTeacher(pickedVariantKey) &&
              !_variantIsFlexible(pickedVariantKey);
          final usesSessions = _variantUsesSessions(pickedVariantKey);
          final usesReminder = _variantUsesReminder(pickedVariantKey);
          final usesStartDate = _variantUsesStartDate(pickedVariantKey);
          final usesExpiry = _variantUsesExpiry(pickedVariantKey);
          final isRecorded = _variantIsRecorded(pickedVariantKey);
          final isServicePayment =
              usesTeacher && _isServiceTeacherLabel(selectedTeacherName ?? '');
          final effectiveUsesSessions = usesSessions && !isServicePayment;
          final effectiveUsesReminder = usesReminder && !isServicePayment;

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
                    _InfoLine(
                      label: 'Current period',
                      value: activePeriod.displayLabel,
                    ),
                    const SizedBox(height: 12),
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

                          if (keys.isEmpty) {
                            return const _MiniHint('Learner has no courses.');
                          }

                          pickedCourseKey ??= keys.first;

                          return DropdownButtonFormField<String>(
                            initialValue: pickedCourseKey,
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: 'Course',
                            ),
                            items: keys
                                .map(
                                  (k) => DropdownMenuItem(
                                    value: k,
                                    child: Text(
                                      labelByKey[k] ?? k,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                )
                                .toList(),
                            selectedItemBuilder: (context) {
                              return keys
                                  .map(
                                    (k) => Align(
                                      alignment: Alignment.centerLeft,
                                      child: Text(
                                        labelByKey[k] ?? k,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  )
                                  .toList();
                            },
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

                    if (effectiveUsesSessions) ...[
                      _NumberPickerRow(
                        label: 'Sessions paid',
                        value: sessionsPaid,
                        min: 1,
                        max: maxSessions,
                        onChanged: (v) {
                          sessionsPaid = v;
                          if (effectiveUsesReminder) {
                            remindBeforeSession = normalizeReminderForSessions(
                              sessionsPaidTotal: sessionsPaid,
                              remindBeforeSession: remindBeforeSession,
                            );
                          }
                          setD(() {});
                        },
                      ),
                      const SizedBox(height: 10),
                    ],

                    if (effectiveUsesReminder) ...[
                      _NumberPickerRow(
                        label: 'Reminder left',
                        value: normalizeReminderForSessions(
                          sessionsPaidTotal: sessionsPaid,
                          remindBeforeSession: remindBeforeSession,
                        ),
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
                        onChanged: (v) {
                          expiryMonths = v;
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

                    if (_variantIsRecorded(pickedVariantKey)) ...[
                      _NumberPickerRow(
                        label: 'Duration months',
                        value: durationMonths,
                        min: 1,
                        max: 12,
                        onChanged: (v) {
                          durationMonths = v;
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
                        labelText: 'Fee (manual)',
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
                    const SizedBox(height: 10),
                    CheckboxListTile(
                      value: sendReceipt,
                      onChanged: (v) => setD(() => sendReceipt = v ?? true),
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: const Text('Send receipt'),
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
                        if (saveLocked) return;
                        saveLocked = true;
                        if (pickedUid == null) {
                          saveLocked = false;
                          _toast('Pick learner first.');
                          return;
                        }
                        if (pickedCourseKey == null ||
                            pickedCourseKey!.trim().isEmpty) {
                          saveLocked = false;
                          _toast('Pick course.');
                          return;
                        }

                        final fee = int.tryParse(amountC.text.trim()) ?? 0;
                        if (fee <= 0) {
                          saveLocked = false;
                          _toast('Fee must be > 0');
                          return;
                        }

                        final paidAtMs = _ymdToMs(paidDateYmd);
                        if (paidAtMs <= 0) {
                          saveLocked = false;
                          _toast('Invalid paid date.');
                          return;
                        }

                        final usesTeacher =
                            _variantUsesTeacher(pickedVariantKey) &&
                            !_variantIsFlexible(pickedVariantKey);
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
                        final isServicePayment =
                            usesTeacher &&
                            _isServiceTeacherLabel(selectedTeacherName ?? '');
                        final effectiveUsesSessions =
                            usesSessions && !isServicePayment;
                        final effectiveUsesReminder =
                            usesReminder && !isServicePayment;

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
                            sessionsPaid: effectiveUsesSessions
                                ? sessionsPaid
                                : 0,
                            durationMonths: _variantIsRecorded(pickedVariantKey)
                                ? durationMonths
                                : 0,
                            amount: fee,
                            dayKey: dayKey,
                          );
                          if (dup) {
                            setD(() => isSaving = false);
                            saveLocked = false;
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

                          final remind = effectiveUsesReminder
                              ? normalizeReminderForSessions(
                                  sessionsPaidTotal: sessionsPaid,
                                  remindBeforeSession: remindBeforeSession,
                                )
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
                            'sessionsPaid': effectiveUsesSessions
                                ? sessionsPaid
                                : null,
                            'remindBeforeSession': effectiveUsesReminder
                                ? remind
                                : null,
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
                            'periodId': activePeriod.id,
                            'periodLabel': activePeriod.displayLabel,
                            'periodStartDate': activePeriod.startDate,
                            'periodStartAtMs': activePeriod.startAtMs,
                          });

                          String postWarning = '';
                          try {
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
                          } catch (syncErr, st) {
                            debugPrint(
                              '[payments][sync][add] paymentId=$paymentId uid=$pickedUid courseKey=$pickedCourseKey variantKey=$pickedVariantKey error=$syncErr\n$st',
                            );
                            postWarning =
                                'Payment saved, but learner summary refresh failed (${humanizeUiMessage(syncErr.toString())}).';
                          }

                          if (sendReceipt) {
                            try {
                              await _sendPaymentReceiptMail(
                                learnerUid: pickedUid!,
                                learnerName: learnerName.isEmpty
                                    ? 'Learner'
                                    : learnerName,
                                courseTitle: courseTitle,
                                amount: fee,
                                sessionsPaid: effectiveUsesSessions
                                    ? sessionsPaid
                                    : 0,
                                paidDateYmd: paidDateYmd,
                                variantKey: pickedVariantKey,
                                durationMonths:
                                    _variantIsRecorded(pickedVariantKey)
                                    ? durationMonths
                                    : 0,
                                expiresAt: expiresAt,
                              );
                            } catch (mailErr) {
                              final mailWarning =
                                  'Receipt mail failed (${humanizeUiMessage(mailErr.toString())}).';
                              postWarning = postWarning.isEmpty
                                  ? 'Payment saved, but $mailWarning'
                                  : '$postWarning $mailWarning';
                            }
                          }

                          if (context.mounted) Navigator.pop(context);
                          _toast('Payment saved ✅');
                          if (postWarning.isNotEmpty) {
                            _toast(postWarning);
                          }
                        } catch (e) {
                          saveLocked = false;
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
    if (_variantUsesReminder(variantKey)) {
      remindBeforeSession = normalizeReminderForSessions(
        sessionsPaidTotal: sessionsPaid,
        remindBeforeSession: remindBeforeSession,
      );
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
    bool saveLocked = false;

    await showDialog<void>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setD) {
          final usesTeacher =
              _variantUsesTeacher(variantKey) &&
              !_variantIsFlexible(variantKey);
          final usesSessions = _variantUsesSessions(variantKey);
          final usesReminder = _variantUsesReminder(variantKey);
          final usesStartDate = _variantUsesStartDate(variantKey);
          final usesExpiry = _variantUsesExpiry(variantKey);
          final isRecorded = _variantIsRecorded(variantKey);
          final isServicePayment =
              usesTeacher && _isServiceTeacherLabel(selectedTeacherName ?? '');
          final effectiveUsesSessions = usesSessions && !isServicePayment;
          final effectiveUsesReminder = usesReminder && !isServicePayment;
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

                    if (effectiveUsesSessions) ...[
                      _NumberPickerRow(
                        label: 'Sessions paid',
                        value: sessionsPaid,
                        min: 1,
                        max: 60,
                        onChanged: (v) {
                          sessionsPaid = v;
                          if (effectiveUsesReminder) {
                            remindBeforeSession = normalizeReminderForSessions(
                              sessionsPaidTotal: sessionsPaid,
                              remindBeforeSession: remindBeforeSession,
                            );
                          }
                          setD(() {});
                        },
                      ),
                      const SizedBox(height: 10),
                    ],

                    if (effectiveUsesReminder) ...[
                      _NumberPickerRow(
                        label: 'Reminder left',
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
                        if (saveLocked) return;
                        saveLocked = true;
                        final fee = int.tryParse(amountC.text.trim()) ?? 0;
                        if (fee <= 0) {
                          saveLocked = false;
                          _toast('Fee must be > 0');
                          return;
                        }

                        final paidAtMs = _ymdToMs(paidDateYmd);
                        if (paidAtMs <= 0) {
                          saveLocked = false;
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
                            'sessionsPaid': effectiveUsesSessions
                                ? sessionsPaid
                                : null,
                            'remindBeforeSession': effectiveUsesReminder
                                ? normalizeReminderForSessions(
                                    sessionsPaidTotal: sessionsPaid,
                                    remindBeforeSession: remindBeforeSession,
                                  )
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

                          String postWarning = '';
                          if (oldUid.isNotEmpty && oldCourseKey.isNotEmpty) {
                            try {
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
                            } catch (syncErr, st) {
                              debugPrint(
                                '[payments][sync][edit] paymentId=$paymentId uid=$oldUid courseKey=$oldCourseKey variantKey=$variantKey error=$syncErr\n$st',
                              );
                              postWarning =
                                  'Payment updated, but summary sync failed (${humanizeUiMessage(syncErr.toString())}).';
                            }
                          }

                          if (context.mounted) Navigator.pop(context);
                          _toast('Updated ✅');
                          if (postWarning.isNotEmpty) {
                            _toast(postWarning);
                          }
                        } catch (e) {
                          saveLocked = false;
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

      String postWarning = '';
      if (uid.isNotEmpty && courseKey.isNotEmpty) {
        try {
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
        } catch (syncErr, st) {
          debugPrint(
            '[payments][sync][delete] paymentId=$paymentId uid=$uid courseKey=$courseKey variantKey=$variantKey error=$syncErr\n$st',
          );
          postWarning =
              'Payment deleted, but learner summary refresh failed (${humanizeUiMessage(syncErr.toString())}).';
        }
      }

      _toast('Deleted ✅');
      if (postWarning.isNotEmpty) {
        _toast(postWarning);
      }
    } catch (e) {
      _toast(toHumanError(e, fallback: 'Could not delete payment.'));
    }
  }
}

class _PaymentPeriodRecord {
  const _PaymentPeriodRecord({
    required this.id,
    required this.label,
    required this.startDate,
    required this.startAtMs,
    required this.endDate,
    required this.endAtMs,
    required this.isActive,
  });

  final String id;
  final String label;
  final String startDate;
  final int startAtMs;
  final String endDate;
  final int endAtMs;
  final bool isActive;

  static int _asInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse((v ?? '').toString()) ?? 0;
  }

  factory _PaymentPeriodRecord.fromMap({
    required String id,
    required Map<String, dynamic> map,
  }) {
    return _PaymentPeriodRecord(
      id: id,
      label: (map['label'] ?? '').toString().trim(),
      startDate: (map['startDate'] ?? '').toString().trim(),
      startAtMs: _asInt(map['startAtMs']),
      endDate: (map['endDate'] ?? '').toString().trim(),
      endAtMs: _asInt(map['endAtMs']),
      isActive: map['isActive'] == true,
    );
  }

  String get displayLabel {
    if (label.isNotEmpty) return label;
    if (startDate.isEmpty) return 'Payment period';
    if (endDate.isNotEmpty) return '$startDate -> $endDate';
    return 'From $startDate';
  }
}

class _ArchiveBucket {
  const _ArchiveBucket({required this.id, required this.label});

  final String id;
  final String label;
}

// ------------------ Compact UI pieces ------------------

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.text, this.strong = false});

  final IconData icon;
  final String text;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: AdminPaymentsScreen.appBg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.black.withValues(alpha: 0.06)),
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
  static const String waitingValue = '__waiting_no_teacher__';
  static const String serviceValue = '__service_no_teacher__';

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

  bool _isWaitingLabel(String name) {
    return name.trim().toLowerCase() == 'waiting';
  }

  bool _isServiceLabel(String name) {
    return name.trim().toLowerCase() == 'service';
  }

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
          final fallback = (fallbackName ?? '').trim();
          if (_isWaitingLabel(fallback)) {
            effectiveUid = waitingValue;
          } else if (_isServiceLabel(fallback)) {
            effectiveUid = serviceValue;
          } else {
            effectiveUid = null;
          }
        }

        return DropdownButtonFormField<String>(
          initialValue: effectiveUid,
          decoration: const InputDecoration(labelText: 'Teacher'),
          items: [
            const DropdownMenuItem<String>(
              value: null,
              child: Text('— Select teacher —'),
            ),
            const DropdownMenuItem<String>(
              value: waitingValue,
              child: Text('Waiting (no teacher yet)'),
            ),
            const DropdownMenuItem<String>(
              value: serviceValue,
              child: Text('Service (school payment)'),
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
            if (uid == waitingValue) {
              onChanged('', 'Waiting');
              return;
            }
            if (uid == serviceValue) {
              onChanged('', 'Service');
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
              separatorBuilder: (_, _) => Divider(
                height: 1,
                color: Colors.black.withValues(alpha: 0.06),
              ),
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
                    style: TextStyle(
                      color: Colors.black.withValues(alpha: 0.6),
                    ),
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
      'peerRole': 'learner',
      'deletedAt': null,
    });

    await indexRef.child(learnerUid).child(threadId).set({
      'subject': subject,
      'updatedAt': now,
      'lastMessage': '',
      'unreadCount': 0,
      'peerUid': meUid,
      'peerName': meName.isEmpty ? 'Admin' : meName,
      'peerRole': 'admin',
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
    'peerRole': 'learner',
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
    m['peerRole'] = 'admin';
    m['deletedAt'] = null;

    return Transaction.success(m);
  });

  await stateRef.child(meUid).child(threadId).update({
    'lastReadAt': now,
    'lastDeliveredAt': now,
  });
  await stateRef.child(learnerUid).child(threadId).update({
    'lastDeliveredAt': now,
  });

  await MailConsistencyService.verifyMailWriteOnce(
    db: db,
    threadId: threadId,
    senderUid: meUid,
    receiverUid: learnerUid,
    senderName: meName.isEmpty ? 'Admin' : meName,
    receiverName: learnerName,
    senderRole: 'admin',
    receiverRole: 'learner',
    subject: subject,
    lastMessage: preview80,
    now: now,
    type: 'mail',
  );
}
