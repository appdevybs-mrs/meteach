import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';

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

  static const List<String> _methods = ['Cash', 'Card', 'Transfer', 'Other'];

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(milliseconds: 900)),
    );
  }

  String _fmtDateFromMs(dynamic ms) {
    final t = _asInt(ms);
    if (t <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(t);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
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

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AdminPaymentsScreen.appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: AdminPaymentsScreen.primaryBlue),
        title: const Text(
          'Payments',
          style: TextStyle(
            color: AdminPaymentsScreen.primaryBlue,
            fontWeight: FontWeight.w900,
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Add payment',
            icon: const Icon(Icons.add_card_rounded, color: AdminPaymentsScreen.actionOrange),
            onPressed: () => _openAddPaymentDialog(),
          ),
        ],
      ),
      body: Column(
        children: [
          // Search bar
          Container(
            color: Colors.white,
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: TextField(
              onChanged: (v) => setState(() => _search = v),
              decoration: InputDecoration(
                hintText: 'Search: learner, serial, teacher, course, notes, dates…',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: AdminPaymentsScreen.appBg,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
            ),
          ),

          // Horizontal-scroll table (header + rows share same width)
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                // Make table wider than screen so it can scroll horizontally
                final tableWidth = constraints.maxWidth < 1100 ? 1100.0 : constraints.maxWidth;

                return SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: tableWidth,
                    child: Column(
                      children: [
                        // Header
                        Container(
                          color: Colors.white,
                          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                          child: _TableHeaderRow(),
                        ),

                        // Rows (vertical scroll)
                        Expanded(
                          child: StreamBuilder<DatabaseEvent>(
                            stream: _paymentsRef.onValue,
                            builder: (context, snap) {
                              if (snap.hasError) {
                                return const Center(child: Text('Error loading payments.'));
                              }
                              if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
                                return const Center(child: CircularProgressIndicator());
                              }

                              final v = snap.data?.snapshot.value;
                              final list = <Map<String, dynamic>>[];

                              if (v is Map) {
                                v.forEach((k, val) {
                                  if (val is Map) {
                                    final m = val.map((kk, vv) => MapEntry(kk.toString(), vv));
                                    m['paymentId'] = k.toString();
                                    list.add(m.cast<String, dynamic>());
                                  }
                                });
                              }

                              list.sort((a, b) => _asInt(b['paidAt']).compareTo(_asInt(a['paidAt'])));

                              final s = _search.trim().toLowerCase();
                              final filtered = s.isEmpty
                                  ? list
                                  : list.where((p) {
                                final learnerName = (p['learner_name'] ?? '').toString().toLowerCase();
                                final serial = (p['learner_serial'] ?? '').toString().toLowerCase();
                                final code = (p['course_code'] ?? '').toString().toLowerCase();
                                final title = (p['course_title'] ?? '').toString().toLowerCase();
                                final teacher = (p['teacherName'] ?? '').toString().toLowerCase();
                                final notes = (p['notes'] ?? '').toString().toLowerCase();
                                final paidDate = _fmtDateFromMs(p['paidAt']).toLowerCase();
                                final startDate = (p['startDate'] ?? '').toString().toLowerCase();
                                return learnerName.contains(s) ||
                                    serial.contains(s) ||
                                    code.contains(s) ||
                                    title.contains(s) ||
                                    teacher.contains(s) ||
                                    notes.contains(s) ||
                                    paidDate.contains(s) ||
                                    startDate.contains(s);
                              }).toList();

                              if (filtered.isEmpty) {
                                return const Center(child: Text('No payments found.'));
                              }

                              return ListView.separated(
                                padding: const EdgeInsets.fromLTRB(12, 0, 12, 18),
                                itemCount: filtered.length,
                                separatorBuilder: (_, __) =>
                                    Divider(height: 1, color: Colors.black.withOpacity(0.07)),
                                itemBuilder: (context, i) {
                                  final p = filtered[i];
                                  final idx = i + 1;

                                  final paidDate = _fmtDateFromMs(p['paidAt']);
                                  final learnerName = (p['learner_name'] ?? '').toString();
                                  final amount = _asInt(p['amount']);
                                  final teacher = (p['teacherName'] ?? '').toString();
                                  final code = (p['course_code'] ?? '').toString();
                                  final sessionsPaid = _asInt(p['sessionsPaid']);
                                  final startDate = (p['startDate'] ?? '').toString();
                                  final remindBeforeSession = _asInt(p['remindBeforeSession']);
                                  final notes = (p['notes'] ?? '').toString();

                                  final rowBg = (i % 2 == 0)
                                      ? Colors.white
                                      : AdminPaymentsScreen.appBg.withOpacity(0.7);

                                  return InkWell(
                                    onTap: () async => _openEditPaymentDialog(p),
                                    child: Container(
                                      color: rowBg,
                                      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
                                      child: Row(
                                        children: [
                                          _cell('#$idx', flex: 1, isStrong: true),
                                          _cell(paidDate.isEmpty ? '—' : paidDate, flex: 2),
                                          _cell(learnerName.isEmpty ? '—' : learnerName, flex: 3),
                                          _cell('$amount', flex: 2, isStrong: true),
                                          _cell(teacher.isEmpty ? '—' : teacher, flex: 3),
                                          _cell(code.isEmpty ? '—' : code, flex: 2),
                                          _cell('$sessionsPaid', flex: 2),
                                          _cell(startDate.isEmpty ? '—' : startDate, flex: 2),
                                          _cell(remindBeforeSession > 0 ? '$remindBeforeSession' : '—', flex: 2),
                                          _cell(notes.isEmpty ? '—' : notes, flex: 4),
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
                                },
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
            color: AdminPaymentsScreen.primaryBlue.withOpacity(isStrong ? 1 : 0.85),
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

    int sessionsPaid = 8;
    int remindBeforeSession = 0;

    final amountC = TextEditingController(text: '0');
    final notesC = TextEditingController();

    String paidDateYmd = _todayYmd();
    String startDateYmd = _todayYmd();

    Map<String, dynamic> pickedLearner = {};
    Map<String, dynamic> pickedCourse = {};

    // ✅ teacher selection (from /users role=teacher)
    String? selectedTeacherUid;
    String? selectedTeacherName;

    await showDialog<void>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setD) {
          return AlertDialog(
            title: const Text('Add payment'),
            content: SizedBox(
              width: 600,
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    _LearnerAutocomplete(
                      usersRef: _usersRef,
                      onPicked: (uid, learnerMap) async {
                        pickedUid = uid;
                        pickedLearner = learnerMap;

                        final coursesSnap = await _usersRef.child(uid).child('courses').get();
                        final coursesVal = coursesSnap.value;

                        pickedCourseKey = null;
                        pickedCourseId = null;
                        pickedCourse = {};

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
                            }
                          }
                        }

                        if (pickedCourseId != null && pickedCourseId!.trim().isNotEmpty) {
                          final cSnap = await _coursesRef.child(pickedCourseId!).get();
                          final cVal = cSnap.value;
                          if (cVal is Map) pickedCourse = cVal.map((k, v) => MapEntry(k.toString(), v));
                        }

                        final totalSessions = _parseTotalSessions((pickedCourse['duration'] ?? '').toString());
                        sessionsPaid = (totalSessions >= 8) ? 8 : (totalSessions > 0 ? totalSessions : 8);
                        amountC.text = _defaultAmount(pickedCourse, sessionsPaid, totalSessions).toString();

                        remindBeforeSession = sessionsPaid;

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

                    if (pickedUid == null)
                      const _MiniHint('Pick learner first.')
                    else
                      FutureBuilder<DataSnapshot>(
                        future: _usersRef.child(pickedUid!).child('courses').get(),
                        builder: (context, snap) {
                          final v = snap.data?.value;
                          final keys = <String>[];
                          final labelByKey = <String, String>{};
                          final idByKey = <String, String>{};

                          if (v is Map) {
                            v.forEach((k, val) {
                              final key = k.toString();
                              if (!key.startsWith('course_')) return;
                              if (val is Map) {
                                final m = val.map((kk, vv) => MapEntry(kk.toString(), vv));
                                final code = (m['course_code'] ?? '').toString().trim();
                                final title = (m['title'] ?? '').toString().trim();
                                final label = [if (code.isNotEmpty) code, if (title.isNotEmpty) title].join(' — ');
                                keys.add(key);
                                labelByKey[key] = label.isNotEmpty ? label : key;
                                idByKey[key] = (m['id'] ?? '').toString();
                              }
                            });
                          }
                          keys.sort();

                          if (keys.isEmpty) return const _MiniHint('Learner has no courses.');

                          pickedCourseKey ??= keys.first;

                          return DropdownButtonFormField<String>(
                            value: pickedCourseKey,
                            decoration: const InputDecoration(labelText: 'Course'),
                            items: keys
                                .map((k) => DropdownMenuItem(value: k, child: Text(labelByKey[k] ?? k)))
                                .toList(),
                            onChanged: (v) async {
                              pickedCourseKey = v;
                              pickedCourseId = (v == null) ? null : idByKey[v];
                              pickedCourse = {};

                              if (pickedCourseId != null && pickedCourseId!.trim().isNotEmpty) {
                                final cSnap = await _coursesRef.child(pickedCourseId!).get();
                                final cVal = cSnap.value;
                                if (cVal is Map) pickedCourse = cVal.map((k, v) => MapEntry(k.toString(), v));
                              }

                              final totalSessions = _parseTotalSessions((pickedCourse['duration'] ?? '').toString());
                              final maxS = (totalSessions > 0) ? totalSessions : 24;
                              if (sessionsPaid > maxS) sessionsPaid = maxS;

                              amountC.text = _defaultAmount(pickedCourse, sessionsPaid, totalSessions).toString();

                              if (remindBeforeSession <= 0) remindBeforeSession = sessionsPaid;
                              if (remindBeforeSession > sessionsPaid) remindBeforeSession = sessionsPaid;

                              setD(() {});
                            },
                          );
                        },
                      ),

                    const SizedBox(height: 12),

                    // ✅ Teacher dropdown from users(role=teacher)
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

                    _NumberPickerRow(
                      label: 'Sessions paid',
                      value: sessionsPaid,
                      min: 1,
                      max: _maxSessionsFromCourse(pickedCourse),
                      onChanged: (v) {
                        sessionsPaid = v;
                        final totalSessions = _parseTotalSessions((pickedCourse['duration'] ?? '').toString());
                        amountC.text = _defaultAmount(pickedCourse, sessionsPaid, totalSessions).toString();

                        if (remindBeforeSession <= 0) remindBeforeSession = sessionsPaid;
                        if (remindBeforeSession > sessionsPaid) remindBeforeSession = sessionsPaid;

                        setD(() {});
                      },
                    ),

                    const SizedBox(height: 10),

                    _NumberPickerRow(
                      label: 'Reminder (before session)',
                      value: (remindBeforeSession <= 0 ? sessionsPaid : remindBeforeSession),
                      min: 1,
                      max: (sessionsPaid > 0 ? sessionsPaid : 1),
                      onChanged: (v) => setD(() => remindBeforeSession = v),
                    ),

                    const SizedBox(height: 10),

                    DropdownButtonFormField<String>(
                      value: method,
                      decoration: const InputDecoration(labelText: 'Method'),
                      items: _methods.map((m) => DropdownMenuItem(value: m, child: Text(m))).toList(),
                      onChanged: (v) => setD(() => method = v ?? method),
                    ),

                    const SizedBox(height: 10),

                    TextFormField(
                      controller: amountC,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Fee (editable)'),
                    ),

                    const SizedBox(height: 10),

                    TextField(
                      controller: notesC,
                      maxLines: 2,
                      decoration: const InputDecoration(labelText: 'Notes (optional)'),
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
                    _toast('Pick learner first.');
                    return;
                  }
                  if (pickedCourseKey == null || pickedCourseKey!.trim().isEmpty) {
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

                  try {
                    final dayKey = paidDateYmd;
                    final dup = await _isDuplicatePayment(
                      uid: pickedUid!,
                      courseKey: pickedCourseKey!,
                      sessionsPaid: sessionsPaid,
                      amount: fee,
                      dayKey: dayKey,
                    );
                    if (dup) {
                      _toast('Duplicate payment blocked ✅');
                      return;
                    }

                    final newRef = _paymentsRef.push();
                    final paymentId = newRef.key!;

                    final courseCode = (pickedCourse['course_code'] ?? '').toString();
                    final courseTitle = (pickedCourse['title'] ?? '').toString();
                    final learnerName =
                    '${(pickedLearner['first_name'] ?? '')} ${(pickedLearner['last_name'] ?? '')}'.trim();
                    final learnerSerial = (pickedLearner['serial'] ?? '').toString();

                    final remind = (remindBeforeSession <= 0 ? sessionsPaid : remindBeforeSession);

                    await newRef.set({
                      'uid': pickedUid,
                      'courseKey': pickedCourseKey,
                      'course_id': pickedCourseId ?? '',
                      'course_code': courseCode,
                      'course_title': courseTitle,

                      'sessionsPaid': sessionsPaid,
                      'remindBeforeSession': remind,

                      'amount': fee,
                      'method': method,

                      // ✅ teacher from users
                      'teacherId': selectedTeacherUid ?? '',
                      'teacherName': selectedTeacherName ?? '',

                      'startDate': startDateYmd,
                      'notes': notesC.text.trim(),

                      'paidAt': paidAtMs,
                      'createdAt': ServerValue.timestamp,

                      'learner_name': learnerName,
                      'learner_serial': learnerSerial,

                      'dayKey': dayKey,
                    });

                    await _updateLearnerSummary(
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
                    _toast('Payment saved ✅');
                  } catch (e) {
                    _toast('Failed: $e');
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

  // ----------------- EDIT / DELETE -----------------

  Future<void> _openEditPaymentDialog(Map<String, dynamic> p) async {
    final paymentId = (p['paymentId'] ?? '').toString();
    if (paymentId.isEmpty) return;

    int sessionsPaid = _asInt(p['sessionsPaid']);
    int remindBeforeSession = _asInt(p['remindBeforeSession']);
    if (remindBeforeSession <= 0) remindBeforeSession = (sessionsPaid > 0 ? sessionsPaid : 1);

    String method = (p['method'] ?? _methods.first).toString();

    final amountC = TextEditingController(text: _asInt(p['amount']).toString());
    final notesC = TextEditingController(text: (p['notes'] ?? '').toString());

    String paidDateYmd = _fmtDateFromMs(p['paidAt']);
    if (paidDateYmd.trim().isEmpty) paidDateYmd = _todayYmd();

    String startDateYmd = (p['startDate'] ?? '').toString();
    if (startDateYmd.trim().isEmpty) startDateYmd = _todayYmd();

    String? selectedTeacherUid = (p['teacherId'] ?? '').toString().trim();
    if (selectedTeacherUid.isEmpty) selectedTeacherUid = null;
    String? selectedTeacherName = (p['teacherName'] ?? '').toString().trim();
    if (selectedTeacherName.isEmpty) selectedTeacherName = null;

    await showDialog<void>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setD) {
          return AlertDialog(
            title: const Text('Edit payment'),
            content: SizedBox(
              width: 600,
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

                    _NumberPickerRow(
                      label: 'Sessions paid',
                      value: sessionsPaid,
                      min: 1,
                      max: 60,
                      onChanged: (v) {
                        sessionsPaid = v;
                        if (remindBeforeSession > sessionsPaid) remindBeforeSession = sessionsPaid;
                        setD(() {});
                      },
                    ),
                    const SizedBox(height: 10),
                    _NumberPickerRow(
                      label: 'Reminder (before session)',
                      value: remindBeforeSession,
                      min: 1,
                      max: (sessionsPaid > 0 ? sessionsPaid : 1),
                      onChanged: (v) => setD(() => remindBeforeSession = v),
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      value: method,
                      decoration: const InputDecoration(labelText: 'Method'),
                      items: _methods.map((m) => DropdownMenuItem(value: m, child: Text(m))).toList(),
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
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
              FilledButton(
                onPressed: () async {
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

                  try {
                    await _paymentsRef.child(paymentId).update({
                      'sessionsPaid': sessionsPaid,
                      'remindBeforeSession': remindBeforeSession,
                      'method': method,
                      'amount': fee,

                      'teacherId': selectedTeacherUid ?? '',
                      'teacherName': selectedTeacherName ?? '',

                      'startDate': startDateYmd,
                      'notes': notesC.text.trim(),

                      'paidAt': paidAtMs,
                      'dayKey': paidDateYmd,
                      'updatedAt': ServerValue.timestamp,
                    });

                    if (context.mounted) Navigator.pop(context);
                    _toast('Updated ✅');
                  } catch (e) {
                    _toast('Failed: $e');
                  }
                },
                child: const Text('Save'),
              )
            ],
          );
        },
      ),
    );
  }

  Future<void> _deletePayment(Map<String, dynamic> p) async {
    final paymentId = (p['paymentId'] ?? '').toString();
    if (paymentId.isEmpty) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete payment?'),
        content: const Text('This will delete the payment record.\n(Does not recalc summaries.)'),
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
      await _paymentsRef.child(paymentId).remove();
      _toast('Deleted ✅');
    } catch (e) {
      _toast('Failed: $e');
    }
  }

  // ----------------- Helpers -----------------

  Future<bool> _isDuplicatePayment({
    required String uid,
    required String courseKey,
    required int sessionsPaid,
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
      if ((m['uid'] ?? '') == uid &&
          (m['courseKey'] ?? '') == courseKey &&
          _asInt(m['sessionsPaid']) == sessionsPaid &&
          _asInt(m['amount']) == amount &&
          (m['dayKey'] ?? '') == dayKey) {
        return true;
      }
    }
    return false;
  }

  Future<void> _updateLearnerSummary({
    required String uid,
    required String courseKey,
    required int addSessionsPaid,
    required int addAmount,
    required String lastPaymentId,
    required String lastMethod,
    required int lastAmount,
    required int remindBeforeSession,
  }) async {
    final sumRef = _usersRef.child(uid).child('courses').child(courseKey).child('payment_summary');

    await sumRef.runTransaction((current) {
      final cur = current is Map ? current.map((k, v) => MapEntry(k.toString(), v)) : <String, dynamic>{};

      final oldTotalPaid = _asInt(cur['totalPaid']);
      final oldSessionsPaid = _asInt(cur['sessionsPaidTotal']);

      final newTotalPaid = oldTotalPaid + addAmount;
      final newSessionsPaidTotal = oldSessionsPaid + addSessionsPaid;

      return Transaction.success({
        ...cur,
        'totalPaid': newTotalPaid,
        'sessionsPaidTotal': newSessionsPaidTotal,
        'remindBeforeSession': remindBeforeSession <= 0
            ? newSessionsPaidTotal
            : (remindBeforeSession > newSessionsPaidTotal ? newSessionsPaidTotal : remindBeforeSession),
        'lastPaymentAt': ServerValue.timestamp,
        'updatedAt': ServerValue.timestamp,
        'lastPaymentId': lastPaymentId,
        'lastMethod': lastMethod,
        'lastAmount': lastAmount,
      });
    });
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

  static int _maxSessionsFromCourse(Map<String, dynamic> course) {
    final total = _parseTotalSessions((course['duration'] ?? '').toString());
    return total > 0 ? total : 24;
  }

  static int _defaultAmount(Map<String, dynamic> course, int sessionsPaid, int totalSessions) {
    final pricePerMonth = _asInt(course['price_per_month']);
    final pricePerLevel = _asInt(course['price_per_level']);

    if (sessionsPaid == 8 && pricePerMonth > 0) return pricePerMonth;
    if (totalSessions > 0 && sessionsPaid == totalSessions && pricePerLevel > 0) return pricePerLevel;

    if (totalSessions > 0 && pricePerLevel > 0) {
      return ((pricePerLevel * sessionsPaid) / totalSessions).round();
    }
    return 0;
  }
}

// ------------------ Table header ------------------

class _TableHeaderRow extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    TextStyle s(bool strong) => TextStyle(
      fontWeight: strong ? FontWeight.w900 : FontWeight.w800,
      color: AdminPaymentsScreen.primaryBlue.withOpacity(0.9),
      fontSize: 12,
    );

    Widget h(String t, {required int flex, bool strong = false}) {
      return Expanded(
        flex: flex,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Text(t, maxLines: 1, overflow: TextOverflow.ellipsis, style: s(strong)),
        ),
      );
    }

    return Row(
      children: [
        h('#', flex: 1, strong: true),
        h('Paid', flex: 2),
        h('Learner', flex: 3, strong: true),
        h('Amount', flex: 2),
        h('Teacher', flex: 3),
        h('Course', flex: 2),
        h('Sessions', flex: 2),
        h('Start', flex: 2),
        h('Remind', flex: 2),
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

  String _labelFor(String uid, Map<String, dynamic> m) {
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

  bool _isTeacherRole(dynamic role) {
    final r = (role ?? '').toString().trim().toLowerCase();
    return r == 'teacher';
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<DataSnapshot>(
      // teachers list rarely changes; one-time fetch is enough
      future: usersRef.get(),
      builder: (context, snap) {
        final v = snap.data?.value;

        final teachers = <Map<String, String>>[]; // {uid, name}

        if (v is Map) {
          v.forEach((k, val) {
            if (k == null || val == null) return;
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

        String? effectiveUid = valueUid;
        if ((effectiveUid == null || effectiveUid.isEmpty) && (fallbackName ?? '').trim().isNotEmpty) {
          final found = teachers.firstWhere(
                (t) => (t['name'] ?? '').trim().toLowerCase() == fallbackName!.trim().toLowerCase(),
            orElse: () => const {'uid': '', 'name': ''},
          );
          if ((found['uid'] ?? '').isNotEmpty) effectiveUid = found['uid'];
        }

        return DropdownButtonFormField<String>(
          value: (effectiveUid != null && effectiveUid!.isNotEmpty) ? effectiveUid : null,
          decoration: const InputDecoration(labelText: 'Teacher'),
          items: [
            const DropdownMenuItem<String>(
              value: null,
              child: Text('— Select teacher —'),
            ),
            ...teachers.map((t) {
              return DropdownMenuItem<String>(
                value: t['uid'],
                child: Text(t['name'] ?? t['uid'] ?? ''),
              );
            }),
          ],
          onChanged: (uid) {
            if (uid == null) {
              onChanged(null, null);
              return;
            }
            final found = teachers.firstWhere((t) => t['uid'] == uid, orElse: () => {'uid': uid, 'name': uid});
            onChanged(uid, found['name'] ?? uid);
          },
        );
      },
    );
  }
}

// ------------------ Learner autocomplete ------------------

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

          final name = '${(m['first_name'] ?? '')} ${(m['last_name'] ?? '')}'.trim().toLowerCase();
          final email = (m['email'] ?? '').toString().toLowerCase();
          final serial = (m['serial'] ?? '').toString().toLowerCase();

          if (name.contains(q) || email.contains(q) || serial.contains(q)) {
            out.add({
              'uid': uid.toString(),
              ...m,
            });
          }
        }
      });
    }

    out.sort((a, b) => ('${a['first_name']} ${a['last_name']}')
        .toString()
        .compareTo('${b['first_name']} ${b['last_name']}'));

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
              border: Border.all(color: Colors.black.withOpacity(0.08)),
            ),
            child: ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _results.length,
              separatorBuilder: (_, __) => Divider(height: 1, color: Colors.black.withOpacity(0.06)),
              itemBuilder: (context, i) {
                final r = _results[i];
                final name = '${(r['first_name'] ?? '')} ${(r['last_name'] ?? '')}'.trim();
                final serial = (r['serial'] ?? '').toString();
                return ListTile(
                  dense: true,
                  title: Text(name, style: const TextStyle(fontWeight: FontWeight.w900)),
                  subtitle: Text(serial, style: TextStyle(color: Colors.black.withOpacity(0.6))),
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
        style: TextStyle(color: Colors.black.withOpacity(0.6), fontWeight: FontWeight.w700),
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
        Expanded(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w900))),
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
