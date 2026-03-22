import 'dart:io';
import 'package:excel/excel.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

class AdminWagesExcelExporter {
  static int _asInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString()) ?? 0;
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _fmtYmdFromMs(int ms) {
    if (ms <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.year}-${_two(d.month)}-${_two(d.day)}';
  }

  static Map<String, Map<String, dynamic>> _mapify(dynamic raw) {
    if (raw is! Map) return {};
    return raw.map(
      (k, v) => MapEntry(
        k.toString(),
        (v is Map)
            ? v.map((kk, vv) => MapEntry(kk.toString(), vv))
            : <String, dynamic>{},
      ),
    );
  }

  static String _str(dynamic v) => (v ?? '').toString().trim();

  /// Export 3 sheets:
  /// 1) Learners: Number, Full Name, Serial
  /// 2) Payments: detailed columns (no UID column)
  /// 3) Summary: Number, Full Name, Date of Payment, Date of Start, Amount, Teacher, Course/Level
  static Future<void> exportAndShareExcel() async {
    final db = FirebaseDatabase.instance;

    // Read all at once (isolated from UI streams)
    final paySnap = await db.ref('payments').get();
    final usersSnap = await db.ref('users').get();

    final paymentsRaw = paySnap.value;
    final usersRaw = usersSnap.value;

    final paymentsMap = _mapify(paymentsRaw);
    final usersMap = _mapify(usersRaw);

    // Build learners list (no UID column)
    final learners = <Map<String, String>>[];
    for (final entry in usersMap.entries) {
      final uid = entry.key;
      final m = entry.value;

      final serial = _str(m['learner_serial'] ?? m['serial'] ?? m['code']);
      final first = _str(m['first_name'] ?? m['firstName']);
      final last = _str(m['last_name'] ?? m['lastName']);

      String name = _str(
        m['learner_name'] ?? m['name'] ?? m['fullName'] ?? m['displayName'],
      );
      if (name.isEmpty) {
        name = [first, last].where((x) => x.isNotEmpty).join(' ').trim();
      }
      if (name.isEmpty) {
        // fallback: show serial if exists else masked uid
        if (serial.isNotEmpty) {
          name = serial;
        } else {
          name = uid.length > 6
              ? 'ID …${uid.substring(uid.length - 6)}'
              : 'ID $uid';
        }
      }

      learners.add({'name': name, 'serial': serial});
    }

    learners.sort(
      (a, b) => a['name']!.toLowerCase().compareTo(b['name']!.toLowerCase()),
    );

    // For course fallback: uid -> courseKey -> {course_title, course_code}
    final Map<String, Map<String, Map<String, String>>> userCourses = {};
    for (final entry in usersMap.entries) {
      final uid = entry.key;
      final m = entry.value;
      final courses = m['courses'];
      if (courses is Map) {
        final cm = courses.map((k, v) => MapEntry(k.toString(), v));
        final out = <String, Map<String, String>>{};
        for (final cEntry in cm.entries) {
          final ck = cEntry.key;
          final cv = cEntry.value;
          if (cv is Map) {
            final c = cv.map((kk, vv) => MapEntry(kk.toString(), vv));
            out[ck] = {
              'course_title': _str(c['course_title']),
              'course_code': _str(c['course_code']),
            };
          }
        }
        userCourses[uid] = out;
      }
    }

    // Payments list
    final payments = <Map<String, dynamic>>[];
    for (final entry in paymentsMap.entries) {
      final pid = entry.key;
      final m = entry.value;
      payments.add({'paymentId': pid, ...m});
    }

    // Sort newest first by paidAt
    payments.sort((a, b) => _asInt(b['paidAt']).compareTo(_asInt(a['paidAt'])));

    // Create workbook
    final excel = Excel.createExcel();

    // Remove default sheet if exists (Excel package usually creates "Sheet1")
    final defaultName = excel.getDefaultSheet();
    if (defaultName != null && excel.sheets.containsKey(defaultName)) {
      // We'll just reuse it as "Learners" to avoid any weirdness
      excel.rename(defaultName, 'Learners');
    }

    // Sheet 1: Learners
    final sheet1 = excel['Learners'];
    sheet1.appendRow([
      TextCellValue('Number'),
      TextCellValue('Full Name'),
      TextCellValue('Serial'),
    ]);
    for (int i = 0; i < learners.length; i++) {
      sheet1.appendRow([
        IntCellValue(i + 1),
        TextCellValue(learners[i]['name'] ?? ''),
        TextCellValue(learners[i]['serial'] ?? ''),
      ]);
    }

    // Sheet 2: Payments (all details needed, but NO UID column)
    final sheet2 = excel['Payments'];
    sheet2.appendRow([
      TextCellValue('Number'),
      TextCellValue('Learner'),
      TextCellValue('Serial'),
      TextCellValue('Date of Payment'),
      TextCellValue('Date of Start'),
      TextCellValue('Course Title'),
      TextCellValue('Course Code'),
      TextCellValue('Sessions Paid'),
      TextCellValue('Reminder Before Session'),
      TextCellValue('Amount'),
      TextCellValue('Teacher'),
      TextCellValue('Method'),
      TextCellValue('Notes'),
      TextCellValue('Day Key'),
      TextCellValue('Month Key'),
      TextCellValue('Payment ID'),
    ]);

    for (int i = 0; i < payments.length; i++) {
      final p = payments[i];

      final learnerName = _str(p['learner_name']);
      final serial = _str(p['learner_serial']);

      final paidAt = _asInt(p['paidAt']);
      final paidDate = _fmtYmdFromMs(paidAt).isNotEmpty
          ? _fmtYmdFromMs(paidAt)
          : _str(p['dayKey']);

      final startDate = _str(p['startDate']);

      String courseTitle = _str(p['course_title']);
      String courseCode = _str(p['course_code']);

      // Fallback from user->courses using uid + courseKey (only if missing)
      if (courseTitle.isEmpty || courseCode.isEmpty) {
        final uid = _str(p['uid']);
        final courseKey = _str(p['courseKey']);
        final cm = userCourses[uid];
        final c = (cm != null && courseKey.isNotEmpty) ? cm[courseKey] : null;
        if (courseTitle.isEmpty) courseTitle = c?['course_title'] ?? '';
        if (courseCode.isEmpty) courseCode = c?['course_code'] ?? '';
      }

      final sessionsPaid = _asInt(p['sessionsPaid']);
      final reminder = _asInt(p['remindBeforeSession']);
      final amount = _asInt(p['amount']);
      final teacherName = _str(p['teacherName']);
      final method = _str(p['method']);
      final notes = _str(p['notes']);
      final dayKey = _str(p['dayKey']);
      final monthKey = _str(p['monthKey']);
      final paymentId = _str(p['paymentId']);

      sheet2.appendRow([
        IntCellValue(i + 1),
        TextCellValue(learnerName),
        TextCellValue(serial),
        TextCellValue(paidDate),
        TextCellValue(startDate),
        TextCellValue(courseTitle),
        TextCellValue(courseCode),
        IntCellValue(sessionsPaid),
        IntCellValue(reminder),
        IntCellValue(amount),
        TextCellValue(teacherName),
        TextCellValue(method),
        TextCellValue(notes),
        TextCellValue(dayKey),
        TextCellValue(monthKey),
        TextCellValue(paymentId),
      ]);
    }

    // Sheet 3: Summary (order exactly as you requested; no title row)
    final sheet3 = excel['Summary'];
    sheet3.appendRow([
      TextCellValue('Number'),
      TextCellValue('Full Name'),
      TextCellValue('Date of Payment'),
      TextCellValue('Date of Start'),
      TextCellValue('Amount'),
      TextCellValue('Teacher'),
      TextCellValue('Course/Level'),
    ]);

    for (int i = 0; i < payments.length; i++) {
      final p = payments[i];

      final learnerName = _str(p['learner_name']);

      final paidAt = _asInt(p['paidAt']);
      final paidDate = _fmtYmdFromMs(paidAt).isNotEmpty
          ? _fmtYmdFromMs(paidAt)
          : _str(p['dayKey']);

      final startDate = _str(p['startDate']);
      final amount = _asInt(p['amount']);
      final teacherName = _str(p['teacherName']);

      String courseTitle = _str(p['course_title']);
      String courseCode = _str(p['course_code']);

      if (courseTitle.isEmpty || courseCode.isEmpty) {
        final uid = _str(p['uid']);
        final courseKey = _str(p['courseKey']);
        final cm = userCourses[uid];
        final c = (cm != null && courseKey.isNotEmpty) ? cm[courseKey] : null;
        if (courseTitle.isEmpty) courseTitle = c?['course_title'] ?? '';
        if (courseCode.isEmpty) courseCode = c?['course_code'] ?? '';
      }

      final courseLevel = [
        if (courseTitle.isNotEmpty) courseTitle,
        if (courseCode.isNotEmpty) '($courseCode)',
      ].join(' ').trim();

      sheet3.appendRow([
        IntCellValue(i + 1),
        TextCellValue(learnerName),
        TextCellValue(paidDate),
        TextCellValue(startDate),
        IntCellValue(amount),
        TextCellValue(teacherName),
        TextCellValue(courseLevel),
      ]);
    }

    // Save to temp and share
    final bytes = excel.encode();
    if (bytes == null) {
      throw Exception('Excel encoding failed');
    }

    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/wages_export.xlsx');
    await file.writeAsBytes(bytes, flush: true);

    await Share.shareXFiles([XFile(file.path)], text: 'Wages export');
  }
}
