import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:dream_english_academy/admin/admin_classes.dart';
import '../shared/app_feedback.dart';
import '../shared/admin_web_layout.dart';

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

  // Visible timetable window: 07:00 -> 00:00
  static const int _visibleStartMin = 7 * 60; // 07:00
  static const int _visibleEndMin = 24 * 60; // 00:00
  static const int _visibleSlots =
      ((_visibleEndMin - _visibleStartMin) ~/ _minutesStep) + 1;

  // Teachers for filter
  bool _loadingTeachers = true;
  final Map<String, Map<String, String>> _teachersByUid = {};
  final Map<String, String> _teacherUidByName = {};

  // Filters
  String _teacherFilterUid = "ALL";
  String _levelTitleFilter = "ALL";
  String _studyTypeFilter = "ALL";
  bool _showOnlyOpen = false;

  // NEW: filter panel collapsed by default
  bool _filtersExpanded = false;
  double _webZoom = 1.0;

  // Scroll controllers
  final ScrollController _hBodyCtrl = ScrollController();
  final ScrollController _hHeaderCtrl = ScrollController();
  final ScrollController _vCtrl = ScrollController();
  bool _syncingH = false;

  @override
  void initState() {
    super.initState();
    _loadTeachers();

    _hBodyCtrl.addListener(() {
      if (_syncingH) return;
      if (!_hHeaderCtrl.hasClients) return;
      _syncingH = true;
      _hHeaderCtrl.jumpTo(
        _hBodyCtrl.offset.clamp(
          _hHeaderCtrl.position.minScrollExtent,
          _hHeaderCtrl.position.maxScrollExtent,
        ),
      );
      _syncingH = false;
    });
  }

  @override
  void dispose() {
    _hBodyCtrl.dispose();
    _hHeaderCtrl.dispose();
    _vCtrl.dispose();
    super.dispose();
  }

  // -------------------- Utilities --------------------

  void _toast(String msg) {
    if (!mounted) return;
    AppToast.fromSnackBar(context, SnackBar(content: Text(msg)));
  }

  String _norm(String s) => s.trim().toLowerCase();

  bool _isTeacherRole(dynamic role) {
    final r = (role ?? "").toString().trim().toLowerCase();
    return r == "teacher" || r == "teachers" || r == "teacher(s)";
  }

  String _classIdOf(Map<String, dynamic> cls) {
    return (cls["class_id"] ?? cls["id"] ?? "").toString().trim();
  }

  String _titleOf(Map<String, dynamic> cls) {
    return (cls["course_title"] ?? "").toString().trim();
  }

  int _learnersCountOf(Map<String, dynamic> cls) {
    final learners = (cls["learners"] is Map)
        ? Map<dynamic, dynamic>.from(cls["learners"])
        : null;
    return learners?.length ?? 0;
  }

  String _variantKeyOf(Map<String, dynamic> cls) {
    final v = (cls["variantKey"] ?? cls["variant_key"] ?? cls["variant"] ?? '')
        .toString()
        .trim()
        .toLowerCase();

    switch (v) {
      case 'in_class':
      case 'in-class':
      case 'in class':
      case 'inclass':
        return 'inclass';
      case 'flexible':
      case 'online':
        return 'flexible';
      case 'private':
      case 'live':
      case 'vip':
        return 'private';
      case 'recorded':
        return 'recorded';
      default:
        return v;
    }
  }

  String _studyModeOf(Map<String, dynamic> cls) {
    final v = (cls["studyMode"] ?? cls["study_mode"] ?? '')
        .toString()
        .trim()
        .toLowerCase();

    switch (v) {
      case 'in_class':
      case 'in-class':
      case 'in class':
      case 'inclass':
        return 'inclass';
      case 'online':
        return 'online';
      default:
        return v;
    }
  }

  String _variantLabelFromKey(String key) {
    switch (key) {
      case 'inclass':
        return 'In-Class';
      case 'flexible':
        return 'Flexible';
      case 'private':
        return 'Private';
      case 'recorded':
        return 'Recorded';
      default:
        return key.trim().isEmpty ? '-' : key;
    }
  }

  String _studyModeLabelFromKey(String key) {
    switch (key) {
      case 'online':
        return 'Online';
      case 'inclass':
        return 'In-Class';
      default:
        return key.trim().isEmpty ? '' : key;
    }
  }

  String _studyTypeLabelOf(Map<String, dynamic> cls) {
    final explicit =
        (cls["studyModeLabel"] ??
                cls["study_mode_label"] ??
                cls["deliveryLabel"] ??
                cls["delivery_label"] ??
                '')
            .toString()
            .trim();
    if (explicit.isNotEmpty) return explicit;

    final variantKey = _variantKeyOf(cls);
    final studyMode = _studyModeOf(cls);

    if (variantKey == 'private') {
      final modeLabel = _studyModeLabelFromKey(studyMode);
      if (modeLabel.isNotEmpty) return 'Private • $modeLabel';
      return 'Private';
    }

    return _variantLabelFromKey(variantKey);
  }

  String _studyTypeFilterValueOf(Map<String, dynamic> cls) {
    final variantKey = _variantKeyOf(cls);
    final studyMode = _studyModeOf(cls);

    if (variantKey == 'private') {
      if (studyMode == 'online') return 'private_online';
      if (studyMode == 'inclass') return 'private_inclass';
      return 'private';
    }

    if (variantKey == 'inclass') return 'inclass';
    if (variantKey == 'flexible') return 'flexible';
    if (variantKey == 'recorded') return 'recorded';

    return 'other';
  }

  String _studyTypeFilterLabel(String value) {
    switch (value) {
      case 'inclass':
        return 'In-Class';
      case 'flexible':
        return 'Flexible';
      case 'private_online':
        return 'Private Online';
      case 'private_inclass':
        return 'Private In-Class';
      case 'private':
        return 'Private';
      case 'recorded':
        return 'Recorded';
      case 'other':
        return 'Other';
      default:
        return value;
    }
  }

  // -------------------- Teacher-based colors --------------------

  static const List<double> _teacherHuePalette = <double>[
    210,
    320,
    150,
    25,
    55,
    0,
    185,
  ];

  String _teacherKey(String instructorName) {
    final t = instructorName.trim();
    if (t.isEmpty) return "#";
    return t[0].toUpperCase();
  }

  double _teacherBaseHue(String instructorName) {
    final key = _teacherKey(instructorName);
    final code = key.codeUnitAt(0);
    final idx = (code >= 65 && code <= 90) ? (code - 65) : 26;
    return _teacherHuePalette[idx % _teacherHuePalette.length];
  }

  int _stableHash(String s) {
    int h = 0;
    for (final cu in s.codeUnits) {
      h = 0x1fffffff & (h + cu);
      h = 0x1fffffff & (h + ((0x0007ffff & h) << 10));
      h ^= (h >> 6);
    }
    h = 0x1fffffff & (h + ((0x03ffffff & h) << 3));
    h ^= (h >> 11);
    h = 0x1fffffff & (h + ((0x00003fff & h) << 15));
    return h;
  }

  HSLColor _classHslForTeacher({
    required String instructorName,
    required String classId,
  }) {
    final hue = _teacherBaseHue(instructorName);
    final h = _stableHash(classId.isEmpty ? "?" : classId);
    final t = (h % 1000) / 999.0;
    final sat = 0.62;
    final light = 0.34 + (t * 0.30);
    return HSLColor.fromAHSL(1.0, hue, sat, light);
  }

  LinearGradient _classGradient({
    required String instructorName,
    required String classId,
  }) {
    final base = _classHslForTeacher(
      instructorName: instructorName,
      classId: classId,
    );
    final c1 = base
        .withLightness((base.lightness + 0.10).clamp(0.0, 1.0))
        .toColor();
    final c2 = base
        .withLightness((base.lightness - 0.05).clamp(0.0, 1.0))
        .toColor();
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [c1, c2],
    );
  }

  Color _classBorderColor({
    required String instructorName,
    required String classId,
  }) {
    final base = _classHslForTeacher(
      instructorName: instructorName,
      classId: classId,
    );
    return base
        .withLightness((base.lightness - 0.12).clamp(0.0, 1.0))
        .toColor();
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

  int _timeToMinutes(String hhmm) {
    final parts = hhmm.split(":");
    if (parts.length != 2) return 0;
    final hh = int.tryParse(parts[0]) ?? 0;
    final mm = int.tryParse(parts[1]) ?? 0;
    return (hh * 60) + mm;
  }

  String _minutesToLabel(int minutes) {
    final hh = (minutes ~/ 60).toString().padLeft(2, '0');
    final mm = (minutes % 60).toString().padLeft(2, '0');
    return "$hh:$mm";
  }

  int _dayIndex(String day) {
    final idx = _weekDays.indexOf(day);
    return idx < 0 ? 0 : idx;
  }

  String _normalizeDayLabel(String day) {
    final d = day.trim().toLowerCase();
    switch (d) {
      case 'sat':
      case 'saturday':
        return 'Sat';
      case 'sun':
      case 'sunday':
        return 'Sun';
      case 'mon':
      case 'monday':
        return 'Mon';
      case 'tue':
      case 'tues':
      case 'tuesday':
        return 'Tue';
      case 'wed':
      case 'wednesday':
        return 'Wed';
      case 'thu':
      case 'thurs':
      case 'thursday':
        return 'Thu';
      case 'fri':
      case 'friday':
        return 'Fri';
      default:
        return '';
    }
  }

  String _initialsWithDots(String name) {
    final clean = name.trim();
    if (clean.isEmpty) return '-';
    final parts = clean
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '-';
    final letters = parts
        .take(3)
        .map((p) => p.substring(0, 1).toUpperCase())
        .toList();
    return '${letters.join('.')}.';
  }

  // -------------------- Sessions progress --------------------

  int _sessionsTotal(Map<String, dynamic> cls) {
    final sched = (cls["schedule"] is Map)
        ? Map<String, dynamic>.from(cls["schedule"])
        : <String, dynamic>{};

    final sc = int.tryParse((sched["sessions_count"] ?? "").toString());
    if (sc != null && sc > 0) return sc;

    final sessions = (sched["sessions"] is List)
        ? List<dynamic>.from(sched["sessions"])
        : const [];
    if (sessions.isNotEmpty) return sessions.length;

    return 0;
  }

  int _sessionsDone(Map<String, dynamic> cls) {
    final att = cls["attendance"];
    if (att is Map) return Map<dynamic, dynamic>.from(att).length;
    if (att is List) return List<dynamic>.from(att).length;
    return 0;
  }

  // -------------------- Filtering --------------------

  bool _matchesFilters(Map<String, dynamic> cls) {
    final bool isOpen = (cls["is_open"] ?? true) == true;
    if (_showOnlyOpen && !isOpen) return false;

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

    if (_levelTitleFilter != "ALL") {
      final title = _titleOf(cls);
      if (title != _levelTitleFilter) return false;
    }

    if (_studyTypeFilter != "ALL") {
      final v = _studyTypeFilterValueOf(cls);
      if (v != _studyTypeFilter) return false;
    }

    return true;
  }

  List<String> _extractLevelTitles(List<Map<String, dynamic>> classes) {
    final set = <String>{};
    for (final cls in classes) {
      final title = _titleOf(cls);
      if (title.isNotEmpty) set.add(title);
    }
    final list = set.toList()..sort();
    return list;
  }

  List<String> _extractStudyTypeFilters(List<Map<String, dynamic>> classes) {
    final set = <String>{};
    for (final cls in classes) {
      final v = _studyTypeFilterValueOf(cls);
      if (v.isNotEmpty && v != 'other') set.add(v);
    }
    final list = set.toList()
      ..sort(
        (a, b) => _studyTypeFilterLabel(a).compareTo(_studyTypeFilterLabel(b)),
      );
    return list;
  }

  // -------------------- Popup --------------------

  void _openClassPopup(Map<String, dynamic> cls) {
    final id = _classIdOf(cls);
    final code = (cls["course_code"] ?? "").toString();
    final title = _titleOf(cls);
    final instructor = (cls["instructor"] ?? "").toString();
    final isOpen = (cls["is_open"] ?? true) == true;
    final status = (cls["status"] ?? "active").toString();
    final studyType = _studyTypeLabelOf(cls);

    final sched = (cls["schedule"] is Map)
        ? Map<String, dynamic>.from(cls["schedule"])
        : <String, dynamic>{};
    final first = (sched["first_session_date"] ?? "").toString();

    final total = _sessionsTotal(cls);
    final done = _sessionsDone(cls);
    final left = (total - done).clamp(0, 999999);
    final learnersCount = _learnersCountOf(cls);

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
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 16,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(999),
                        color: (isOpen ? Colors.green : Colors.red).withValues(
                          alpha: 0.12,
                        ),
                        border: Border.all(
                          color: (isOpen ? Colors.green : Colors.red)
                              .withValues(alpha: 0.35),
                        ),
                      ),
                      child: Text(
                        isOpen ? "OPEN" : "CLOSED",
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          color: isOpen ? Colors.green : Colors.red,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  "Class ID: $id",
                  style: TextStyle(
                    color: Colors.grey.shade800,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  "Instructor: $instructor",
                  style: TextStyle(
                    color: Colors.grey.shade800,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  "Study type: ${studyType.isEmpty ? '-' : studyType}",
                  style: TextStyle(
                    color: Colors.grey.shade800,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  "Status: $status",
                  style: TextStyle(
                    color: Colors.grey.shade800,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: Colors.grey.withValues(alpha: 0.25),
                    ),
                    color: Colors.black.withValues(alpha: 0.03),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          "Sessions: ${total == 0 ? "-" : total}",
                          style: const TextStyle(fontWeight: FontWeight.w900),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          "Studied: ${total == 0 ? "-" : done}",
                          style: const TextStyle(fontWeight: FontWeight.w900),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          "Left: ${total == 0 ? "-" : left}",
                          style: const TextStyle(fontWeight: FontWeight.w900),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  "Start: ${first.isEmpty ? "-" : first} • Learners: $learnersCount",
                  style: TextStyle(
                    color: Colors.grey.shade800,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Navigator.pop(context);
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) =>
                              AdminClassesScreen(openClassSearchId: id),
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

  // -------------------- Adaptive sizing --------------------

  _Sizes _calcSizes(BoxConstraints c) {
    final w = c.maxWidth;
    final baseTimeGutterW = (w * 0.16).clamp(56.0, 80.0);
    final baseDayColW = (w * 0.34).clamp(120.0, 180.0);
    final baseSlotH = (w * 0.085).clamp(28.0, 44.0);

    final zoom = isWebDesktop(context) ? _webZoom : 1.0;
    final timeGutterW = (baseTimeGutterW * zoom).clamp(56.0, 96.0);
    final dayColW = (baseDayColW * zoom).clamp(120.0, 240.0);
    final slotH = (baseSlotH * zoom).clamp(24.0, 62.0);

    return _Sizes(timeGutterW: timeGutterW, dayColW: dayColW, slotH: slotH);
  }

  // -------------------- Sticky Header --------------------

  Widget _stickyHeader(double fullW, _Sizes s) {
    return Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Container(
        padding: const EdgeInsets.only(bottom: 6),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: Colors.grey.withValues(alpha: 0.20)),
          ),
        ),
        child: SingleChildScrollView(
          controller: _hHeaderCtrl,
          scrollDirection: Axis.horizontal,
          physics: const NeverScrollableScrollPhysics(),
          child: SizedBox(
            width: fullW,
            height: 34,
            child: Row(
              children: [
                SizedBox(
                  width: s.timeGutterW,
                  child: const Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: Text(
                      "Time",
                      style: TextStyle(fontWeight: FontWeight.w900),
                    ),
                  ),
                ),
                ..._weekDays.map(
                  (d) => SizedBox(
                    width: s.dayColW,
                    child: Center(
                      child: Text(
                        d,
                        style: const TextStyle(fontWeight: FontWeight.w900),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // -------------------- Grid background --------------------

  Widget _gridBackground(double gridH, double fullW, _Sizes s) {
    return CustomPaint(
      size: Size(fullW, gridH),
      painter: _TimetableGridPainter(
        timeGutterW: s.timeGutterW,
        dayColW: s.dayColW,
        slotH: s.slotH,
        slots: _visibleSlots,
        dayCount: _weekDays.length,
      ),
    );
  }

  // -------------------- Blocks overlay --------------------

  List<_SessionBlock> _collectSessionBlocks(
    List<Map<String, dynamic>> classes,
  ) {
    final out = <_SessionBlock>[];

    for (final cls in classes) {
      final bool isOpen = (cls["is_open"] ?? true) == true;
      final classId = _classIdOf(cls);
      final instructor = (cls["instructor"] ?? "").toString().trim();

      final gradient = _classGradient(
        instructorName: instructor,
        classId: classId,
      );
      final borderColor = _classBorderColor(
        instructorName: instructor,
        classId: classId,
      );

      final sched = (cls["schedule"] is Map)
          ? Map<String, dynamic>.from(cls["schedule"])
          : <String, dynamic>{};
      final sessions = (sched["sessions"] is List)
          ? List<dynamic>.from(sched["sessions"])
          : <dynamic>[];

      if (sessions.isEmpty) continue;

      for (final sess in sessions) {
        final m = (sess is Map)
            ? Map<String, dynamic>.from(sess)
            : <String, dynamic>{};

        final day = _normalizeDayLabel((m["day"] ?? "").toString());
        final start = (m["start_time"] ?? "").toString().trim();
        final dur = int.tryParse((m["duration_min"] ?? "0").toString()) ?? 0;

        if (day.isEmpty || start.isEmpty || dur <= 0) continue;

        if (!RegExp(r'^\d{2}:\d{2}$').hasMatch(start)) continue;

        final startMin = _timeToMinutes(start);
        final endMin = startMin + dur;

        final visStart = startMin < _visibleStartMin
            ? _visibleStartMin
            : startMin;
        final visEnd = endMin > _visibleEndMin ? _visibleEndMin : endMin;
        if (visEnd <= visStart) continue;

        final title = _titleOf(cls);
        final learnersCount = _learnersCountOf(cls);
        final studyType = _studyTypeLabelOf(cls);
        out.add(
          _SessionBlock(
            cls: cls,
            dayIdx: _dayIndex(day),
            visStartMin: visStart,
            visEndMin: visEnd,
            isOpen: isOpen,
            title: title,
            learnersCount: learnersCount,
            studyType: studyType,
            instructor: instructor,
            gradient: gradient,
            borderColor: borderColor,
          ),
        );
      }
    }

    return out;
  }

  List<Widget> _buildBlocks(List<Map<String, dynamic>> classes, _Sizes s) {
    final blocks = <Widget>[];
    final sessions = _collectSessionBlocks(classes);

    final byDay = <int, List<_SessionBlock>>{};
    for (final b in sessions) {
      byDay.putIfAbsent(b.dayIdx, () => <_SessionBlock>[]).add(b);
    }

    byDay.forEach((_, dayBlocks) {
      dayBlocks.sort((a, b) {
        final sCmp = a.visStartMin.compareTo(b.visStartMin);
        if (sCmp != 0) return sCmp;
        return a.visEndMin.compareTo(b.visEndMin);
      });

      final active = <_SessionBlock>[];

      for (final block in dayBlocks) {
        active.removeWhere((x) => x.visEndMin <= block.visStartMin);
        final usedCols = active.map((x) => x.col).toSet();
        int col = 0;
        while (usedCols.contains(col)) {
          col++;
        }
        block.col = col;
        active.add(block);

        final laneCount = active.length;
        for (final a in active) {
          if (a.laneCount < laneCount) a.laneCount = laneCount;
        }
      }

      for (final block in dayBlocks) {
        final overlapPeers = dayBlocks
            .where(
              (other) =>
                  !(other.visEndMin <= block.visStartMin ||
                      other.visStartMin >= block.visEndMin),
            )
            .toList();
        if (overlapPeers.isEmpty) continue;

        final maxLane = overlapPeers
            .map((x) => x.laneCount)
            .reduce((a, b) => a > b ? a : b);

        final dayWidth = s.dayColW - 4;
        const colGap = 2.0;
        const minLaneWidth = 58.0;
        final computedMaxLanes = ((dayWidth + colGap) / (minLaneWidth + colGap))
            .floor();
        final maxLanes = computedMaxLanes < 1 ? 1 : computedMaxLanes;

        if (maxLane <= maxLanes) {
          block.denseRank = 0;
          block.denseCount = 1;
          continue;
        }

        final densePeers =
            overlapPeers.where((x) => x.col >= (maxLanes - 1)).toList()
              ..sort((a, b) {
                final sCmp = a.visStartMin.compareTo(b.visStartMin);
                if (sCmp != 0) return sCmp;
                return a.visEndMin.compareTo(b.visEndMin);
              });

        block.denseCount = densePeers.isEmpty ? 1 : densePeers.length;
        if (block.col >= (maxLanes - 1)) {
          final idx = densePeers.indexOf(block);
          block.denseRank = idx < 0 ? 0 : idx;
        } else {
          block.denseRank = 0;
        }
      }
    });

    for (final b in sessions) {
      final top = ((b.visStartMin - _visibleStartMin) / _minutesStep) * s.slotH;
      final rawHeight =
          (((b.visEndMin - b.visStartMin) / _minutesStep) * s.slotH) - 1;
      final height = rawHeight.clamp(18.0, double.infinity);

      const dayInset = 2.0;
      const colGap = 2.0;
      const minLaneWidth = 58.0;
      final dayLeft = s.timeGutterW + (b.dayIdx * s.dayColW) + dayInset;
      final dayWidth = s.dayColW - (dayInset * 2);
      final laneCount = b.laneCount < 1 ? 1 : b.laneCount;
      final computedMaxLanes = ((dayWidth + colGap) / (minLaneWidth + colGap))
          .floor();
      final maxLanes = computedMaxLanes < 1 ? 1 : computedMaxLanes;
      final renderLanes = laneCount > maxLanes ? maxLanes : laneCount;
      final gapTotal = (renderLanes - 1) * colGap;
      final colW = (dayWidth - gapTotal) / renderLanes;

      final denseMode = laneCount > maxLanes;
      final renderCol = denseMode
          ? (b.col < (renderLanes - 1) ? b.col : (renderLanes - 1))
          : b.col;
      final left = dayLeft + (renderCol * (colW + colGap));

      double blockTop = top;
      double blockHeight = height;

      if (denseMode && b.col >= (renderLanes - 1)) {
        final stackCount = b.denseCount < 1 ? 1 : b.denseCount;
        final rank = b.denseRank < 0 ? 0 : b.denseRank;
        final stackGap = stackCount > 1 ? (stackCount - 1) * 1.0 : 0.0;
        final perHeight = ((height - stackGap) / stackCount).clamp(
          14.0,
          height,
        );
        blockTop = top + (rank * (perHeight + 1.0));
        blockHeight = perHeight;
      }

      blocks.add(
        Positioned(
          left: left,
          top: blockTop,
          width: colW,
          height: blockHeight,
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => _openClassPopup(b.cls),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                gradient: b.gradient,
                border: Border.all(
                  color: b.isOpen
                      ? b.borderColor.withValues(alpha: 0.70)
                      : Colors.red.withValues(alpha: 0.75),
                ),
              ),
              child: LayoutBuilder(
                builder: (context, c) {
                  final tiny = c.maxHeight < 34;
                  final compact = c.maxHeight < 46;
                  final fsTitle = tiny ? 8.8 : (compact ? 9.6 : 10.6);
                  final fsSub = tiny ? 8.0 : (compact ? 8.8 : 9.6);
                  final showStudyType = !tiny;
                  final showClosed = !b.isOpen && !tiny;
                  final showDenseBadge =
                      denseMode &&
                      b.col >= (renderLanes - 1) &&
                      b.denseRank == 0 &&
                      b.denseCount > 1;

                  return Stack(
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            "${b.title.isEmpty ? "Untitled" : b.title} • ${b.learnersCount}",
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.w900,
                              fontSize: fsTitle,
                              height: 1.0,
                              color: Colors.black.withValues(alpha: 0.88),
                            ),
                          ),
                          if (showStudyType)
                            Text(
                              b.studyType.isEmpty ? "-" : b.studyType,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: fsSub,
                                height: 1.0,
                                color: Colors.black.withValues(alpha: 0.84),
                              ),
                            ),
                          Text(
                            _initialsWithDots(
                              b.instructor.isEmpty
                                  ? "No teacher"
                                  : b.instructor,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: fsSub,
                              height: 1.0,
                              color: Colors.black.withValues(alpha: 0.82),
                            ),
                          ),
                          if (showClosed)
                            const Text(
                              "CLOSED",
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.red,
                                fontWeight: FontWeight.w900,
                                fontSize: 10,
                                height: 1.0,
                              ),
                            ),
                        ],
                      ),
                      if (showDenseBadge)
                        Align(
                          alignment: Alignment.topRight,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              '+${b.denseCount - 1}',
                              style: TextStyle(
                                fontSize: tiny ? 7.0 : 8.0,
                                fontWeight: FontWeight.w900,
                                color: Colors.black.withValues(alpha: 0.85),
                                height: 1.0,
                              ),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      );
    }

    return blocks;
  }

  // -------------------- Compact top bar --------------------

  Widget _topCompactBar({required int shownCount}) {
    final activeFiltersCount = [
      _teacherFilterUid != "ALL",
      _levelTitleFilter != "ALL",
      _studyTypeFilter != "ALL",
      _showOnlyOpen,
    ].where((x) => x).length;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: Colors.grey.withValues(alpha: 0.25)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                "Showing $shownCount class${shownCount == 1 ? '' : 'es'}",
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
            ),
            if (activeFiltersCount > 0)
              Container(
                margin: const EdgeInsets.only(right: 8),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  color: Colors.blue.withValues(alpha: 0.10),
                  border: Border.all(
                    color: Colors.blue.withValues(alpha: 0.25),
                  ),
                ),
                child: Text(
                  "$activeFiltersCount filter${activeFiltersCount == 1 ? '' : 's'}",
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    color: Colors.blue,
                  ),
                ),
              ),
            IconButton(
              tooltip: _filtersExpanded ? "Hide filters" : "Show filters",
              onPressed: () =>
                  setState(() => _filtersExpanded = !_filtersExpanded),
              icon: Icon(
                _filtersExpanded
                    ? Icons.keyboard_arrow_up_rounded
                    : Icons.keyboard_arrow_down_rounded,
              ),
            ),
            if (isWebDesktop(context))
              SegmentedButton<double>(
                segments: const [
                  ButtonSegment(value: 0.85, label: Text('85%')),
                  ButtonSegment(value: 1.0, label: Text('100%')),
                  ButtonSegment(value: 1.2, label: Text('120%')),
                ],
                selected: <double>{_webZoom},
                onSelectionChanged: (v) {
                  setState(() {
                    _webZoom = v.first;
                  });
                },
              ),
          ],
        ),
      ),
    );
  }

  // -------------------- Filters UI --------------------

  Widget _filtersCard({
    required List<String> levelTitles,
    required List<String> studyTypes,
    required double maxWidth,
  }) {
    final twoCols = maxWidth >= 520;

    final teacherDrop = DropdownButtonFormField<String>(
      isExpanded: true,
      initialValue: _teacherFilterUid,
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
    );

    final levelDrop = DropdownButtonFormField<String>(
      isExpanded: true,
      initialValue: _levelTitleFilter,
      decoration: const InputDecoration(
        labelText: "Level",
        border: OutlineInputBorder(),
        isDense: true,
      ),
      items: [
        const DropdownMenuItem(value: "ALL", child: Text("All levels")),
        ...levelTitles.map(
          (t) => DropdownMenuItem(
            value: t,
            child: Text(t, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ),
      ],
      onChanged: (v) => setState(() => _levelTitleFilter = v ?? "ALL"),
    );

    final studyTypeDrop = DropdownButtonFormField<String>(
      isExpanded: true,
      initialValue: _studyTypeFilter,
      decoration: const InputDecoration(
        labelText: "Study type",
        border: OutlineInputBorder(),
        isDense: true,
      ),
      items: [
        const DropdownMenuItem(value: "ALL", child: Text("All study types")),
        ...studyTypes.map(
          (t) => DropdownMenuItem(
            value: t,
            child: Text(
              _studyTypeFilterLabel(t),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ],
      onChanged: (v) => setState(() => _studyTypeFilter = v ?? "ALL"),
    );

    final toggle = SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: const Text(
        "Only open",
        style: TextStyle(fontWeight: FontWeight.w800),
      ),
      value: _showOnlyOpen,
      onChanged: (v) => setState(() => _showOnlyOpen = v),
    );

    final clearButton = Align(
      alignment: Alignment.centerRight,
      child: TextButton.icon(
        onPressed: () {
          setState(() {
            _teacherFilterUid = "ALL";
            _levelTitleFilter = "ALL";
            _studyTypeFilter = "ALL";
            _showOnlyOpen = false;
          });
        },
        icon: const Icon(Icons.filter_alt_off_rounded),
        label: const Text("Clear filters"),
      ),
    );

    return AnimatedCrossFade(
      duration: const Duration(milliseconds: 180),
      crossFadeState: _filtersExpanded
          ? CrossFadeState.showSecond
          : CrossFadeState.showFirst,
      firstChild: const SizedBox.shrink(),
      secondChild: Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: Colors.grey.withValues(alpha: 0.25)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (twoCols)
                Row(
                  children: [
                    Expanded(child: teacherDrop),
                    const SizedBox(width: 10),
                    Expanded(child: levelDrop),
                  ],
                )
              else ...[
                teacherDrop,
                const SizedBox(height: 10),
                levelDrop,
              ],
              const SizedBox(height: 10),
              studyTypeDrop,
              const SizedBox(height: 6),
              toggle,
              clearButton,
            ],
          ),
        ),
      ),
      // same height placeholder when collapsed
      secondCurve: Curves.easeOut,
      firstCurve: Curves.easeIn,
    );
  }

  // -------------------- Main build --------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Weekly Timetable"),
        actions: [
          const SizedBox.shrink(),
          IconButton(
            tooltip: "Reload teachers",
            onPressed: _loadTeachers,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: adminWebBodyFrame(
        context: context,
        maxWidth: 1700,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: StreamBuilder<DatabaseEvent>(
            stream: _classesRef.onValue,
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }

              final classes = _parseClasses(snap.data?.snapshot.value);
              if (classes.isEmpty) {
                return const Center(child: Text("No classes found."));
              }

              final levelTitles = _extractLevelTitles(classes);
              final studyTypes = _extractStudyTypeFilters(classes);
              final filtered = classes.where(_matchesFilters).toList();

              return LayoutBuilder(
                builder: (context, c) {
                  final s = _calcSizes(c);

                  final gridH = _visibleSlots * s.slotH;
                  final fullW = s.timeGutterW + (_weekDays.length * s.dayColW);

                  return Column(
                    children: [
                      _topCompactBar(shownCount: filtered.length),
                      if (_filtersExpanded) const SizedBox(height: 8),
                      _filtersCard(
                        levelTitles: levelTitles,
                        studyTypes: studyTypes,
                        maxWidth: c.maxWidth,
                      ),
                      const SizedBox(height: 10),
                      Expanded(
                        child: Column(
                          children: [
                            _stickyHeader(fullW, s),
                            Expanded(
                              child: Scrollbar(
                                controller: _vCtrl,
                                thumbVisibility: true,
                                child: SingleChildScrollView(
                                  controller: _vCtrl,
                                  child: Scrollbar(
                                    controller: _hBodyCtrl,
                                    thumbVisibility: true,
                                    notificationPredicate: (n) =>
                                        n.metrics.axis == Axis.horizontal,
                                    child: SingleChildScrollView(
                                      controller: _hBodyCtrl,
                                      scrollDirection: Axis.horizontal,
                                      child: SizedBox(
                                        width: fullW,
                                        height: gridH,
                                        child: Stack(
                                          children: [
                                            _gridBackground(gridH, fullW, s),
                                            Positioned(
                                              left: 0,
                                              top: 0,
                                              bottom: 0,
                                              width: s.timeGutterW,
                                              child: Column(
                                                children: List.generate(
                                                  _visibleSlots,
                                                  (i) {
                                                    final minutes =
                                                        _visibleStartMin +
                                                        (i * _minutesStep);
                                                    final isHour =
                                                        (minutes % 60) == 0;

                                                    return SizedBox(
                                                      height: s.slotH,
                                                      child: Align(
                                                        alignment:
                                                            Alignment.topLeft,
                                                        child: Padding(
                                                          padding:
                                                              const EdgeInsets.only(
                                                                left: 8,
                                                                top: 2,
                                                              ),
                                                          child: Text(
                                                            isHour
                                                                ? _minutesToLabel(
                                                                    minutes,
                                                                  )
                                                                : "",
                                                            style: TextStyle(
                                                              fontSize: 11,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w800,
                                                              color: Colors
                                                                  .grey
                                                                  .shade800,
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                                    );
                                                  },
                                                ),
                                              ),
                                            ),
                                            ..._buildBlocks(filtered, s),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }
}

class _Sizes {
  _Sizes({
    required this.timeGutterW,
    required this.dayColW,
    required this.slotH,
  });

  final double timeGutterW;
  final double dayColW;
  final double slotH;
}

class _SessionBlock {
  _SessionBlock({
    required this.cls,
    required this.dayIdx,
    required this.visStartMin,
    required this.visEndMin,
    required this.isOpen,
    required this.title,
    required this.learnersCount,
    required this.studyType,
    required this.instructor,
    required this.gradient,
    required this.borderColor,
  });

  final Map<String, dynamic> cls;
  final int dayIdx;
  final int visStartMin;
  final int visEndMin;
  final bool isOpen;
  final String title;
  final int learnersCount;
  final String studyType;
  final String instructor;
  final LinearGradient gradient;
  final Color borderColor;
  int col = 0;
  int laneCount = 1;
  int denseRank = 0;
  int denseCount = 1;
}

class _TimetableGridPainter extends CustomPainter {
  _TimetableGridPainter({
    required this.timeGutterW,
    required this.dayColW,
    required this.slotH,
    required this.slots,
    required this.dayCount,
  });

  final double timeGutterW;
  final double dayColW;
  final double slotH;
  final int slots;
  final int dayCount;

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = Colors.grey.withValues(alpha: 0.20)
      ..strokeWidth = 1;

    final strong = Paint()
      ..color = Colors.grey.withValues(alpha: 0.35)
      ..strokeWidth = 1;

    for (int d = 0; d <= dayCount; d++) {
      final x = timeGutterW + (d * dayColW);
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), strong);
    }
    canvas.drawLine(
      Offset(timeGutterW, 0),
      Offset(timeGutterW, size.height),
      strong,
    );

    for (int s = 0; s <= slots; s++) {
      final y = s * slotH;
      final minutesFromStart = s * 30;
      final isHour = (minutesFromStart % 60) == 0;
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        isHour ? strong : line,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
