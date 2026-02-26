import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../services/push_client.dart';

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

  // ✅ Compact filters
  String? _selectedMonthYyyyMm; // "2026-02"

  // ✅ Multi-select (ticks)
  final Set<String> _selectedPaymentIds = {};

  static const List<String> _methods = ['Cash', 'Card', 'Transfer', 'Other'];

  void _toast(String msg) {
    if (!mounted) return;
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

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DatabaseEvent>(
      stream: _paymentsRef.onValue,
      builder: (context, snap) {
        if (snap.hasError) {
          return const Scaffold(body: Center(child: Text('Error loading payments.')));
        }
        if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }

        // Build list
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

        // Sort newest first
        all.sort((a, b) => _asInt(a['createdAt']).compareTo(_asInt(b['createdAt'])));
        // Month options
        final monthsSet = <String>{};
        for (final p in all) {
          final mm = _fmtMonthFromMs(p['paidAt']);
          if (mm.isNotEmpty) monthsSet.add(mm);
        }
        final months = monthsSet.toList()..sort((a, b) => b.compareTo(a));

        // If selected month disappeared, reset
        if (_selectedMonthYyyyMm != null && !monthsSet.contains(_selectedMonthYyyyMm)) {
          _selectedMonthYyyyMm = null;
        }

        // Search filter
        final s = _search.trim().toLowerCase();
        final searchFiltered = s.isEmpty
            ? all
            : all.where((p) {
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

        // Month filter (paidAt-based)
        final visible = (_selectedMonthYyyyMm == null)
            ? searchFiltered
            : searchFiltered
            .where((p) => _fmtMonthFromMs(p['paidAt']) == _selectedMonthYyyyMm)
            .toList();

        // ✅ Today total (global; ignores filters/search)
        final today = _todayYmd();
        final todayTotal = _sumAmount(all.where((p) => (p['dayKey'] ?? '') == today));

        // ✅ Totals
        final visibleTotal = _sumAmount(visible);

        final monthTotal = _sumAmount((_selectedMonthYyyyMm == null)
            ? all
            : all.where((p) => _fmtMonthFromMs(p['paidAt']) == _selectedMonthYyyyMm));

        // ✅ Selected total (only from visible rows)
        int selectedTotal = 0;
        int selectedCount = 0;
        if (_selectedPaymentIds.isNotEmpty) {
          final visibleById = <String, Map<String, dynamic>>{};
          for (final p in visible) {
            visibleById[(p['paymentId'] ?? '').toString()] = p;
          }

          // If some selections are not visible anymore, drop them
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

        // App bar actions: today pill + add button
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
            iconTheme: const IconThemeData(color: AdminPaymentsScreen.primaryBlue),
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
                icon: const Icon(Icons.add_card_rounded, color: AdminPaymentsScreen.actionOrange),
                onPressed: () => _openAddPaymentDialog(),
              ),
              const SizedBox(width: 6),
            ],
          ),
          body: Column(
            children: [
              // Search bar
              Container(
                color: Colors.white,
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
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

              // ✅ Compact toolbar row (Month filter ONLY)
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
                          ...months.map((m) => DropdownMenuItem<String?>(
                            value: m,
                            child: Text(m),
                          )),
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

                      // ✅ Selected appears ONLY when selected
                      if (selectedCount > 0) ...[
                        const SizedBox(width: 8),
                        _Pill(
                          icon: Icons.check_circle_rounded,
                          text: 'Selected ($selectedCount): ${_fmtMoneyDa(selectedTotal)}',
                          color: AdminPaymentsScreen.actionOrange.withOpacity(0.18),
                          borderColor: AdminPaymentsScreen.actionOrange.withOpacity(0.35),
                        ),
                        IconButton(
                          tooltip: 'Clear selection',
                          onPressed: () => setState(() => _selectedPaymentIds.clear()),
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

              // Table
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final tableWidth =
                    constraints.maxWidth < 1100 ? 1100.0 : constraints.maxWidth;

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
                            // ✅ Header row now scrolls with table
                            Container(
                              color: Colors.white,
                              alignment: Alignment.center,
                              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                              child: ConstrainedBox(
                                constraints: BoxConstraints(maxWidth: tableWidth),
                                child: _TableHeaderRow(),
                              ),
                            ),
                            Divider(height: 1, color: Colors.black.withOpacity(0.07)),
                            Expanded(
                              child: ListView.separated(
                                padding: const EdgeInsets.fromLTRB(0, 0, 0, 18),
                                itemCount: visible.length,
                                separatorBuilder: (_, __) =>
                                    Divider(height: 1, color: Colors.black.withOpacity(0.07)),
                                itemBuilder: (context, i) {
                                  final p = visible[i];
                                  final idx = i + 1;

                                  final paymentId = (p['paymentId'] ?? '').toString();
                                  final isSelected = _selectedPaymentIds.contains(paymentId);

                                  final paidDate = _fmtDateFromMs(p['paidAt']);
                                  final startDate = (p['startDate'] ?? '').toString();
                                  final learnerName = (p['learner_name'] ?? '').toString();
                                  final amount = _asInt(p['amount']);
                                  final teacher = (p['teacherName'] ?? '').toString();
                                  final courseTitle = (p['course_title'] ?? '').toString();
                                  final notes = (p['notes'] ?? '').toString();

                                  final baseRowBg = (i % 2 == 0)
                                      ? Colors.white
                                      : AdminPaymentsScreen.appBg.withOpacity(0.7);
                                  final rowBg = isSelected
                                      ? AdminPaymentsScreen.actionOrange.withOpacity(0.14)
                                      : baseRowBg;

                                  final selectionMode = _selectedPaymentIds.isNotEmpty;

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
                                            _selectedPaymentIds.remove(paymentId);
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
                                          vertical: 10, horizontal: 6),
                                      child: Row(
                                        children: [
                                          // ✅ Tick column
                                          SizedBox(
                                            width: 34,
                                            child: Center(
                                              child: AnimatedSwitcher(
                                                duration:
                                                const Duration(milliseconds: 120),
                                                child: isSelected
                                                    ? const Icon(Icons.check_circle,
                                                    size: 18,
                                                    color:
                                                    AdminPaymentsScreen.actionOrange)
                                                    : Icon(Icons.radio_button_unchecked,
                                                    size: 18,
                                                    color: AdminPaymentsScreen.primaryBlue
                                                        .withOpacity(0.25)),
                                              ),
                                            ),
                                          ),

                                          _cell('#$idx', flex: 1, isStrong: true),
                                          _cell(paidDate.isEmpty ? '—' : paidDate, flex: 2),
                                          _cell(learnerName.isEmpty ? '—' : learnerName,
                                              flex: 3),
                                          _cell('$amount', flex: 2, isStrong: true),
                                          _cell(teacher.isEmpty ? '—' : teacher, flex: 3),
                                          _cell(courseTitle.isEmpty ? '—' : courseTitle,
                                              flex: 3),
                                          _cell(startDate.isEmpty ? '—' : startDate, flex: 2),
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
                                                  PopupMenuItem(
                                                      value: 'edit', child: Text('Edit')),
                                                  PopupMenuDivider(),
                                                  PopupMenuItem(
                                                      value: 'delete', child: Text('Delete')),
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

    String? selectedTeacherUid;
    String? selectedTeacherName;

    bool isSaving = false; // ✅ prevents multi-tap duplicate saves

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

                        final coursesSnap =
                        await _usersRef.child(uid).child('courses').get();
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
                              final node =
                              firstNode.map((k, v) => MapEntry(k.toString(), v));
                              pickedCourseId = (node['id'] ?? '').toString();
                            }
                          }
                        }

                        if (pickedCourseId != null && pickedCourseId!.trim().isNotEmpty) {
                          final cSnap = await _coursesRef.child(pickedCourseId!).get();
                          final cVal = cSnap.value;
                          if (cVal is Map) {
                            pickedCourse = cVal.map((k, v) => MapEntry(k.toString(), v));
                          }
                        }

                        final totalSessions = _parseTotalSessions(
                            (pickedCourse['duration'] ?? '').toString());
                        sessionsPaid =
                        (totalSessions >= 8) ? 8 : (totalSessions > 0 ? totalSessions : 8);
                        amountC.text =
                            _defaultAmount(pickedCourse, sessionsPaid, totalSessions).toString();

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
                                final label = [
                                  if (code.isNotEmpty) code,
                                  if (title.isNotEmpty) title
                                ].join(' — ');
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
                                .map((k) =>
                                DropdownMenuItem(value: k, child: Text(labelByKey[k] ?? k)))
                                .toList(),
                            onChanged: (v) async {
                              pickedCourseKey = v;
                              pickedCourseId = (v == null) ? null : idByKey[v];
                              pickedCourse = {};

                              if (pickedCourseId != null && pickedCourseId!.trim().isNotEmpty) {
                                final cSnap =
                                await _coursesRef.child(pickedCourseId!).get();
                                final cVal = cSnap.value;
                                if (cVal is Map) {
                                  pickedCourse = cVal.map((k, v) => MapEntry(k.toString(), v));
                                }
                              }

                              final totalSessions = _parseTotalSessions(
                                  (pickedCourse['duration'] ?? '').toString());
                              final maxS = (totalSessions > 0) ? totalSessions : 24;
                              if (sessionsPaid > maxS) sessionsPaid = maxS;

                              amountC.text = _defaultAmount(
                                  pickedCourse, sessionsPaid, totalSessions)
                                  .toString();

                              if (remindBeforeSession <= 0) remindBeforeSession = sessionsPaid;
                              if (remindBeforeSession > sessionsPaid) {
                                remindBeforeSession = sessionsPaid;
                              }

                              setD(() {});
                            },
                          );
                        },
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
                      max: _maxSessionsFromCourse(pickedCourse),
                      onChanged: (v) {
                        sessionsPaid = v;
                        final totalSessions = _parseTotalSessions(
                            (pickedCourse['duration'] ?? '').toString());
                        amountC.text =
                            _defaultAmount(pickedCourse, sessionsPaid, totalSessions).toString();

                        if (remindBeforeSession <= 0) remindBeforeSession = sessionsPaid;
                        if (remindBeforeSession > sessionsPaid) {
                          remindBeforeSession = sessionsPaid;
                        }

                        setD(() {});
                      },
                    ),
                    const SizedBox(height: 10),
                    _NumberPickerRow(
                      label: 'Reminder when left',
                      value: (remindBeforeSession <= 0 ? sessionsPaid : remindBeforeSession),
                      min: 1,
                      max: (sessionsPaid > 0 ? sessionsPaid : 1),
                      onChanged: (v) => setD(() => remindBeforeSession = v),
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      value: method,
                      decoration: const InputDecoration(labelText: 'Method'),
                      items: _methods
                          .map((m) => DropdownMenuItem(value: m, child: Text(m)))
                          .toList(),
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

                  // ✅ lock button immediately
                  setD(() => isSaving = true);

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
                      setD(() => isSaving = false);
                      _toast('Duplicate payment blocked ✅');
                      return;
                    }

                    final newRef = _paymentsRef.push();
                    final paymentId = newRef.key!;

                    final courseCode = (pickedCourse['course_code'] ?? '').toString();
                    final courseTitle = (pickedCourse['title'] ?? '').toString();
                    final learnerName =
                    '${(pickedLearner['first_name'] ?? '')} ${(pickedLearner['last_name'] ?? '')}'
                        .trim();
                    final learnerSerial = (pickedLearner['serial'] ?? '').toString();

                    final remind =
                    (remindBeforeSession <= 0 ? sessionsPaid : remindBeforeSession);

                    final monthKey = paidDateYmd.substring(0, 7);

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
                      'teacherId': selectedTeacherUid ?? '',
                      'teacherName': selectedTeacherName ?? '',
                      'startDate': startDateYmd,
                      'notes': notesC.text.trim(),
                      'paidAt': paidAtMs,
                      'createdAt': ServerValue.timestamp,
                      'learner_name': learnerName,
                      'learner_serial': learnerSerial,
                      'dayKey': dayKey,
                      'monthKey': monthKey,
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

                    await _sendPaymentReceiptMail(
                      learnerUid: pickedUid!,
                      learnerName: learnerName.isEmpty ? 'Learner' : learnerName,
                      courseTitle: courseTitle,
                      amount: fee,
                      sessionsPaid: sessionsPaid,
                      paidDateYmd: paidDateYmd,
                    );

                    if (context.mounted) Navigator.pop(context);
                    _toast('Payment saved ✅');
                  } catch (e) {
                    setD(() => isSaving = false);
                    _toast('Failed: $e');
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

    // Keep these so we can recalc correctly if courseKey/uid changes (it usually doesn't)
    final oldUid = (p['uid'] ?? '').toString().trim();
    final oldCourseKey = (p['courseKey'] ?? '').toString().trim();

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

    bool isSaving = false; // ✅ prevents multi-tap duplicate updates

    await showDialog<void>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setD) {
          return AlertDialog(
            title: Text(titleName),
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
                      label: 'Reminder when left',
                      value: remindBeforeSession,
                      min: 1,
                      max: (sessionsPaid > 0 ? sessionsPaid : 1),
                      onChanged: (v) => setD(() => remindBeforeSession = v),
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      value: method,
                      decoration: const InputDecoration(labelText: 'Method'),
                      items: _methods
                          .map((m) => DropdownMenuItem(value: m, child: Text(m)))
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
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
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
                      'monthKey': monthKey,
                      'updatedAt': ServerValue.timestamp,
                    });

                    // ✅ keep summary correct after edit
                    if (oldUid.isNotEmpty && oldCourseKey.isNotEmpty) {
                      await _recalcLearnerSummaryForCourse(
                          uid: oldUid, courseKey: oldCourseKey);
                    }

                    if (context.mounted) Navigator.pop(context);
                    _toast('Updated ✅');
                  } catch (e) {
                    setD(() => isSaving = false);
                    _toast('Failed: $e');
                  }
                },
                child: Text(isSaving ? 'Saving…' : 'Save'),
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
        content:
        const Text('This will delete the payment record.\n(Does not recalc summaries.)'),
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

      // ✅ keep summary correct after delete
      final uid = (p['uid'] ?? '').toString().trim();
      final courseKey = (p['courseKey'] ?? '').toString().trim();
      if (uid.isNotEmpty && courseKey.isNotEmpty) {
        await _recalcLearnerSummaryForCourse(uid: uid, courseKey: courseKey);
      }

      setState(() => _selectedPaymentIds.remove(paymentId));
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
      final cur = current is Map
          ? current.map((k, v) => MapEntry(k.toString(), v))
          : <String, dynamic>{};

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
            : (remindBeforeSession > newSessionsPaidTotal
            ? newSessionsPaidTotal
            : remindBeforeSession),
        'lastPaymentAt': ServerValue.timestamp,
        'updatedAt': ServerValue.timestamp,
        'lastPaymentId': lastPaymentId,
        'lastMethod': lastMethod,
        'lastAmount': lastAmount,
      });
    });
  }

  Future<void> _recalcLearnerSummaryForCourse({
    required String uid,
    required String courseKey,
  }) async {
    final sumRef = _usersRef.child(uid).child('courses').child(courseKey).child('payment_summary');
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

        totalPaid += amount;
        sessionsTotal += sp;

        if (paidAt >= lastPaidAt) {
          lastPaidAt = paidAt;
          lastPaymentId = entry.key.toString();
          lastMethod = method;
          lastAmount = amount;
          lastRemind = remind;
        }
      }
    }

    int remindBeforeSession =
    (lastRemind > 0) ? lastRemind : _asInt(oldSum['remindBeforeSession']);

    if (sessionsTotal <= 0) {
      remindBeforeSession = 0;
    } else {
      if (remindBeforeSession <= 0) remindBeforeSession = sessionsTotal;
      if (remindBeforeSession > sessionsTotal) remindBeforeSession = sessionsTotal;
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
        border: Border.all(color: borderColor ?? Colors.black.withOpacity(0.06)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: AdminPaymentsScreen.primaryBlue.withOpacity(0.85)),
          const SizedBox(width: 8),
          Text(
            text,
            style: TextStyle(
              fontWeight: strong ? FontWeight.w900 : FontWeight.w800,
              color: AdminPaymentsScreen.primaryBlue.withOpacity(0.92),
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
        border: Border.all(color: Colors.black.withOpacity(0.06)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$label:',
            style: TextStyle(
              fontWeight: FontWeight.w900,
              color: AdminPaymentsScreen.primaryBlue.withOpacity(0.85),
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
                color: AdminPaymentsScreen.primaryBlue.withOpacity(0.92),
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
        const SizedBox(width: 34), // tick space
        h('#', flex: 1, strong: true),
        h('Paid', flex: 2),
        h('Learner', flex: 3, strong: true),
        h('Amount', flex: 2),
        h('Teacher', flex: 3),
        h('Class', flex: 3),
        h('Start', flex: 2),
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

    final name = (m['name'] ?? m['full_name'] ?? m['fullName'] ?? '').toString().trim();
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
          value: effectiveUid,
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

Future<void> _sendPaymentReceiptMail({
  required String learnerUid,
  required String learnerName,
  required String courseTitle,
  required int amount,
  required int sessionsPaid,
  required String paidDateYmd,
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

  final body = '✅ Payment received\n'
      'Course: $courseTitle\n'
      'Sessions: $sessionsPaid\n'
      'Amount: $amount DA\n'
      'Paid date: $paidDateYmd\n';

  String? threadId;

  final adminIndexSnap = await indexRef.child(meUid).get();
  final v = adminIndexSnap.value;

  if (v is Map) {
    for (final e in v.entries) {
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
    final oldUnread = (m['unreadCount'] is num) ? (m['unreadCount'] as num).toInt() : 0;

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