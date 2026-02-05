// lib/admin/admin_timetable_screen.dart
import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:dream_english_academy/admin/admin_classes.dart';

class AdminTimetableScreen extends StatefulWidget {
  const AdminTimetableScreen({super.key});

  @override
  State<AdminTimetableScreen> createState() => _AdminTimetableScreenState();
}

class _AdminTimetableScreenState extends State<AdminTimetableScreen> {
  // ===== DB NODES =====
  static const String classesNode = "classes";
  static const String usersNode = "users";

  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  late final DatabaseReference _classesRef = _db.child(classesNode);
  late final DatabaseReference _usersRef = _db.child(usersNode);

  // Sat -> Fri
  static const List<String> _weekDays = <String>[
    "Sat",
    "Sun",
    "Mon",
    "Tue",
    "Wed",
    "Thu",
    "Fri",
  ];

  // 30-min grid
  static const int _minutesStep = 30;
  static const int _slotsPerDay = (24 * 60) ~/ _minutesStep; // 48

  // UI sizing
  static const double _timeGutterW = 66;
  static const double _dayColW = 150;
  static const double _slotH = 36;

  // Teachers for filter
  bool _loadingTeachers = true;
  final Map<String, Map<String, String>> _teachersByUid = {};
  final Map<String, String> _teacherUidByName = {};

  // Filters
  String _teacherFilterUid = "ALL";
  String _levelFilter = "ALL";
  bool _showOnlyOpen = false;

  // scroll (one horizontal controller shared by header + grid)
  final ScrollController _hCtrl = ScrollController();
  final ScrollController _vCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    _loadTeachers();
  }

  @override
  void dispose() {
    _hCtrl.dispose();
    _vCtrl.dispose();
    super.dispose();
  }

  // -------------------- Utilities --------------------

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  String _norm(String s) => s.trim().toLowerCase();

  bool _isTeacherRole(dynamic role) {
    final r = (role ?? "").toString().trim().toLowerCase();
    return r == "teacher" || r == "teachers" || r == "teacher(s)";
  }

  // -------------------- Load teachers --------------------

  Future<void> _loadTeachers() async {
    setState(() => _loadingTeachers = true);

    try {
      final snap = await _usersRef.get();
      _teachersByUid.clear();
      _teacherUidByName.clear();

      if (snap.exists && snap.value is Map) {
        final all = Map<dynamic, dynamic>.from(snap.value as Map);

        for (final entry in all.entries) {
          final uid = entry.key.toString();
          final data = (entry.value is Map)
              ? Map<String, dynamic>.from(entry.value as Map)
              : <String, dynamic>{};

          if (!_isTeacherRole(data["role"])) continue;

          final first = (data["first_name"] ?? "").toString().trim();
          final last = (data["last_name"] ?? "").toString().trim();
          final full = "$first $last".trim();
          final serial = (data["serial"] ?? "").toString().trim();

          final teacher = <String, String>{
            "uid": uid,
            "name": full.isEmpty ? uid : full,
            "serial": serial,
          };

          _teachersByUid[uid] = teacher;
          if (full.isNotEmpty) _teacherUidByName[_norm(full)] = uid;
        }
      }
    } catch (e) {
      _toast("Failed to load teachers: $e");
    }

    if (!mounted) return;
    setState(() => _loadingTeachers = false);
  }

  List<Map<String, String>> get _teachersSorted {
    final list = _teachersByUid.values.toList();
    list.sort((a, b) => (a["name"] ?? "").compareTo(b["name"] ?? ""));
    return list;
  }

  // -------------------- Time helpers --------------------

  int _timeToSlotIndex(String hhmm) {
    final parts = hhmm.split(":");
    if (parts.length != 2) return 0;
    final hh = int.tryParse(parts[0]) ?? 0;
    final mm = int.tryParse(parts[1]) ?? 0;
    final total = (hh * 60) + mm;
    return (total ~/ _minutesStep).clamp(0, _slotsPerDay - 1);
  }

  String _slotLabel(int slotIndex) {
    final totalMin = slotIndex * _minutesStep;
    final hh = (totalMin ~/ 60).toString().padLeft(2, '0');
    final mm = (totalMin % 60).toString().padLeft(2, '0');
    return "$hh:$mm";
  }

  int _dayIndex(String day) {
    final idx = _weekDays.indexOf(day);
    return idx < 0 ? 0 : idx;
  }

  // -------------------- Filtering --------------------

  bool _matchesFilters(Map<String, dynamic> cls) {
    final bool isOpen = (cls["is_open"] ?? true) == true;
    if (_showOnlyOpen && !isOpen) return false;

    // teacher filter
    if (_teacherFilterUid != "ALL") {
      String uid = "";
      final cur = cls["instructor_current"];
      if (cur is Map) {
        final m = Map<String, dynamic>.from(cur);
        uid = (m["uid"] ?? "").toString().trim();
      }
      if (uid.isEmpty) {
        final name = (cls["instructor"] ?? "").toString().trim();
        uid = _teacherUidByName[_norm(name)] ?? "";
      }
      if (uid != _teacherFilterUid) return false;
    }

    // level filter
    if (_levelFilter != "ALL") {
      final lvl = (cls["course_level"] ?? cls["level"] ?? "").toString().trim();
      if (lvl != _levelFilter) return false;
    }

    return true;
  }

  List<String> _extractLevels(List<Map<String, dynamic>> classes) {
    final set = <String>{};
    for (final cls in classes) {
      final lvl = (cls["course_level"] ?? cls["level"] ?? "").toString().trim();
      if (lvl.isNotEmpty) set.add(lvl);
    }
    final list = set.toList()..sort();
    return list;
  }

  // -------------------- Popup --------------------

  void _openClassPopup(Map<String, dynamic> cls) {
    final id = (cls["class_id"] ?? "").toString();
    final code = (cls["course_code"] ?? "").toString();
    final title = (cls["course_title"] ?? "").toString();
    final instructor = (cls["instructor"] ?? "").toString();
    final isOpen = (cls["is_open"] ?? true) == true;
    final status = (cls["status"] ?? "active").toString();

    final sched = (cls["schedule"] is Map)
        ? Map<String, dynamic>.from(cls["schedule"])
        : <String, dynamic>{};
    final first = (sched["first_session_date"] ?? "").toString();
    final count = (sched["sessions_count"] ?? "").toString();

    final learners = (cls["learners"] is Map) ? Map<dynamic, dynamic>.from(cls["learners"]) : null;
    final learnersCount = learners?.length ?? 0;

    showModalBottomSheet(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        "$code — $title",
                        style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(999),
                        color: (isOpen ? Colors.green : Colors.black).withOpacity(0.12),
                        border: Border.all(
                          color: (isOpen ? Colors.green : Colors.black).withOpacity(0.30),
                        ),
                      ),
                      child: Text(
                        isOpen ? "OPEN" : "CLOSED",
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          color: isOpen ? Colors.green : Colors.black,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text("Class ID: $id", style: TextStyle(color: Colors.grey.shade800, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text("Instructor: $instructor", style: TextStyle(color: Colors.grey.shade800, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text("Status: $status", style: TextStyle(color: Colors.grey.shade800, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(
                  "Start: ${first.isEmpty ? "-" : first} • Sessions: ${count.isEmpty ? "-" : count} • Learners: $learnersCount",
                  style: TextStyle(color: Colors.grey.shade800, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Navigator.pop(context); // close bottom sheet

                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => AdminClassesScreen(openClassId: id),
                        ),
                      );
                    },

                    icon: const Icon(Icons.open_in_new),
                    label: const Text("Open in Admin Classes"),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // -------------------- Grid painter background --------------------

  Widget _gridBackground(double gridH) {
    return CustomPaint(
      size: Size(_timeGutterW + (_weekDays.length * _dayColW), gridH),
      painter: _TimetableGridPainter(
        timeGutterW: _timeGutterW,
        dayColW: _dayColW,
        slotH: _slotH,
        slotsPerDay: _slotsPerDay,
        dayCount: _weekDays.length,
      ),
    );
  }

  // -------------------- Blocks overlay --------------------

  List<Widget> _buildBlocks(List<Map<String, dynamic>> classes) {
    final List<Widget> blocks = [];

    for (final cls in classes) {
      final bool isOpen = (cls["is_open"] ?? true) == true;

      final sched = (cls["schedule"] is Map)
          ? Map<String, dynamic>.from(cls["schedule"])
          : <String, dynamic>{};
      final sessions = (sched["sessions"] is List)
          ? List<dynamic>.from(sched["sessions"])
          : <dynamic>[];

      if (sessions.isEmpty) continue;

      for (final s in sessions) {
        final m = (s is Map) ? Map<String, dynamic>.from(s) : <String, dynamic>{};
        final day = (m["day"] ?? "").toString().trim();
        final start = (m["start_time"] ?? "").toString().trim();
        final dur = int.tryParse((m["duration_min"] ?? "0").toString()) ?? 0;

        if (day.isEmpty || start.isEmpty || dur <= 0) continue;

        final dayIdx = _dayIndex(day);
        final startSlot = _timeToSlotIndex(start);
        final span = (dur / _minutesStep).round().clamp(1, _slotsPerDay);

        final top = startSlot * _slotH;
        final left = _timeGutterW + (dayIdx * _dayColW) + 4;
        final width = _dayColW - 8;
        final height = (span * _slotH) - 4;

        final code = (cls["course_code"] ?? "").toString();
        final title = (cls["course_title"] ?? "").toString();
        final instructor = (cls["instructor"] ?? "").toString();
        final id = (cls["class_id"] ?? "").toString();

        blocks.add(
          Positioned(
            left: left,
            top: top + 2,
            width: width,
            height: height,
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => _openClassPopup(cls),
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  color: (isOpen ? Colors.green : Colors.black).withOpacity(isOpen ? 0.12 : 0.10),
                  border: Border.all(
                    color: (isOpen ? Colors.green : Colors.black).withOpacity(isOpen ? 0.35 : 0.25),
                  ),
                ),
                child: DefaultTextStyle(
                  style: TextStyle(
                    color: isOpen ? Colors.green.shade900 : Colors.black,
                    fontWeight: FontWeight.w800,
                    fontSize: 12,
                    height: 1.1,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(code.isEmpty ? title : code, maxLines: 1, overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 4),
                      Text(start, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900)),
                      const Spacer(),
                      Text(instructor, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
                      Text(id, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      }
    }

    return blocks;
  }

  // -------------------- Parse classes --------------------

  List<Map<String, dynamic>> _parseClasses(dynamic raw) {
    if (raw == null || raw is! Map) return [];
    final map = Map<dynamic, dynamic>.from(raw);

    final list = <Map<String, dynamic>>[];
    for (final entry in map.entries) {
      if (entry.value is! Map) continue;
      final cls = Map<String, dynamic>.from(entry.value as Map);
      cls["class_id"] = (cls["class_id"] ?? entry.key).toString();
      list.add(cls);
    }
    return list;
  }

  // -------------------- Main build --------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Weekly Timetable"),
        actions: [
          IconButton(
            tooltip: "Reload teachers",
            onPressed: _loadTeachers,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: StreamBuilder<DatabaseEvent>(
          stream: _classesRef.onValue,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }

            final classes = _parseClasses(snap.data?.snapshot.value);
            if (classes.isEmpty) return const Center(child: Text("No classes found."));

            final levels = _extractLevels(classes);

            final filtered = classes.where(_matchesFilters).toList();

            final gridH = _slotsPerDay * _slotH;
            final fullW = _timeGutterW + (_weekDays.length * _dayColW);

            return Column(
              children: [
                // Filters card (no overflow: compact + Wrap)
                Card(
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                    side: BorderSide(color: Colors.grey.withOpacity(0.25)),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                    child: Column(
                      children: [
                        Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            SizedBox(
                              width: 280,
                              child: DropdownButtonFormField<String>(
                                isExpanded: true,
                                value: _teacherFilterUid,
                                decoration: const InputDecoration(
                                  labelText: "Teacher",
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                ),
                                items: [
                                  const DropdownMenuItem(value: "ALL", child: Text("All teachers")),
                                  ..._teachersSorted.map((t) {
                                    final uid = (t["uid"] ?? "").toString();
                                    final name = (t["name"] ?? "").toString();
                                    final serial = (t["serial"] ?? "").toString();
                                    return DropdownMenuItem(
                                      value: uid,
                                      child: Text(
                                        "$name${serial.isEmpty ? "" : " ($serial)"}",
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    );
                                  }),
                                ],
                                onChanged: _loadingTeachers
                                    ? null
                                    : (v) => setState(() => _teacherFilterUid = v ?? "ALL"),
                              ),
                            ),
                            SizedBox(
                              width: 180,
                              child: DropdownButtonFormField<String>(
                                isExpanded: true,
                                value: _levelFilter,
                                decoration: const InputDecoration(
                                  labelText: "Level",
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                ),
                                items: [
                                  const DropdownMenuItem(value: "ALL", child: Text("All levels")),
                                  ...levels.map((lvl) => DropdownMenuItem(value: lvl, child: Text(lvl))),
                                ],
                                onChanged: (v) => setState(() => _levelFilter = v ?? "ALL"),
                              ),
                            ),
                            SizedBox(
                              width: 180,
                              child: SwitchListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text("Only open", style: TextStyle(fontWeight: FontWeight.w800)),
                                value: _showOnlyOpen,
                                onChanged: (v) => setState(() => _showOnlyOpen = v),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 10),

                // Timetable (header + grid share the SAME horizontal scroll controller)
                Expanded(
                  child: Scrollbar(
                    controller: _vCtrl,
                    thumbVisibility: true,
                    child: SingleChildScrollView(
                      controller: _vCtrl,
                      child: Scrollbar(
                        controller: _hCtrl,
                        thumbVisibility: true,
                        notificationPredicate: (n) => n.metrics.axis == Axis.horizontal,
                        child: SingleChildScrollView(
                          controller: _hCtrl,
                          scrollDirection: Axis.horizontal,
                          child: SizedBox(
                            width: fullW,
                            child: Column(
                              children: [
                                // Header row
                                SizedBox(
                                  height: 34,
                                  child: Row(
                                    children: [
                                      SizedBox(
                                        width: _timeGutterW,
                                        child: const Padding(
                                          padding: EdgeInsets.only(left: 8),
                                          child: Text("Time", style: TextStyle(fontWeight: FontWeight.w900)),
                                        ),
                                      ),
                                      ..._weekDays.map((d) => SizedBox(
                                        width: _dayColW,
                                        child: Center(
                                          child: Text(d, style: const TextStyle(fontWeight: FontWeight.w900)),
                                        ),
                                      )),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 6),

                                // Grid + labels + blocks
                                SizedBox(
                                  height: gridH,
                                  child: Stack(
                                    children: [
                                      _gridBackground(gridH),

                                      // Time labels
                                      Positioned(
                                        left: 0,
                                        top: 0,
                                        bottom: 0,
                                        width: _timeGutterW,
                                        child: Column(
                                          children: List.generate(_slotsPerDay, (i) {
                                            final isHour = ((i * _minutesStep) % 60) == 0;
                                            return SizedBox(
                                              height: _slotH,
                                              child: Align(
                                                alignment: Alignment.topLeft,
                                                child: Padding(
                                                  padding: const EdgeInsets.only(left: 8, top: 2),
                                                  child: Text(
                                                    isHour ? _slotLabel(i) : "",
                                                    style: TextStyle(
                                                      fontSize: 11,
                                                      fontWeight: FontWeight.w800,
                                                      color: Colors.grey.shade800,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            );
                                          }),
                                        ),
                                      ),

                                      // Blocks
                                      ..._buildBlocks(filtered),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _TimetableGridPainter extends CustomPainter {
  _TimetableGridPainter({
    required this.timeGutterW,
    required this.dayColW,
    required this.slotH,
    required this.slotsPerDay,
    required this.dayCount,
  });

  final double timeGutterW;
  final double dayColW;
  final double slotH;
  final int slotsPerDay;
  final int dayCount;

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = Colors.grey.withOpacity(0.20)
      ..strokeWidth = 1;

    final strong = Paint()
      ..color = Colors.grey.withOpacity(0.35)
      ..strokeWidth = 1;

    // Vertical separators
    for (int d = 0; d <= dayCount; d++) {
      final x = timeGutterW + (d * dayColW);
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), strong);
    }
    // Time gutter border
    canvas.drawLine(Offset(timeGutterW, 0), Offset(timeGutterW, size.height), strong);

    // Horizontal lines
    for (int s = 0; s <= slotsPerDay; s++) {
      final y = s * slotH;
      final minutes = s * 30;
      final isHour = (minutes % 60) == 0;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), isHour ? strong : line);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
