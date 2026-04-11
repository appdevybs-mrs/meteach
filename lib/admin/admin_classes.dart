// lib/admin/admin_classes.dart
//
// ✅ Updates (WITHOUT breaking your logic / DB structure / working features)
//
// 1) Class card order changed (as you requested):
//    - Starts with: course_level + course_title
//    - Then: course_id
//    - Then the rest
//    - Removed showing course_code everywhere in the LIST card (and also in the editor “Course:” preview)
//
// 2) Open / Closed badge improved (clear colors)
//
// 3) FIXED learner picker bug:
//    - If learner becomes NOT enrolled after you previously selected them,
//      you can NOW untick them (we only block ticking ON, not ticking OFF).
//    - Also, before saving: we auto-remove any selected learners who are no longer enrolled
//      (so the dialog can always save, and you won’t get stuck).
//
// 4) Added filter per day (Sat..Fri) + "All days"
//    - Works by checking class.schedule.sessions[].day
//
// 5) Added search per learner (optional but useful):
//    - Searching now also matches learner name/serial inside cls["learners"]
//
// 6) Extra small useful UI:
//    - Filter chips: All / Open only / Closed only
//    - Small summary line: “Showing X of Y”
//    - Keeps ALL existing create/edit/delete/status/schedule/sync logic intact.
//

import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:intl/intl.dart';
import '../shared/app_feedback.dart';
import '../shared/admin_web_layout.dart';
import '../shared/human_error.dart';
import '../shared/payment_status.dart';
import '../shared/study_variant.dart';
import 'admin_learners.dart';

class AdminClassesScreen extends StatefulWidget {
  final String? openClassId;
  const AdminClassesScreen({super.key, this.openClassId});

  @override
  State<AdminClassesScreen> createState() => _AdminClassesScreenState();
}

class _AdminClassesScreenState extends State<AdminClassesScreen> {
  // ====== DB NODES ======
  static const String coursesNode = "courses";
  static const String classesNode = "classes";
  static const String usersNode = "users";
  static const String syllabiNode = "syllabi";
  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  late final DatabaseReference _coursesRef = _db.child(coursesNode);
  late final DatabaseReference _classesRef = _db.child(classesNode);
  late final DatabaseReference _usersRef = _db.child(usersNode);
  late final DatabaseReference _syllabiRef = _db.child(syllabiNode);
  // ===== Courses cache =====
  bool _loadingCourses = true;
  List<Map<String, dynamic>> _courses = [];
  late final Future<void> _bootFuture;
  Future<DataSnapshot>? _classesFuture;

  // ===== Learners cache (ALL learners) =====
  bool _loadingLearners = true;
  List<Map<String, dynamic>> _allLearners =
      []; // {uid, serial, name, coursesMap}

  // ===== Teachers cache (ALL teachers) =====
  bool _loadingTeachers = true;
  Map<String, Map<String, String>> _teachersByUid =
      {}; // uid -> {uid,name,serial}
  Map<String, String> _teacherUidByName = {}; // normalizedFullName -> uid
  // ✅ Cache progress per class (so list scrolling is smooth)
  final Map<String, _ClassProg> _classProgCache = {};
  final Map<String, int> _syllabusSessionCountCache = <String, int>{};
  final Map<String, Map<int, Map<String, dynamic>>> _flexibleSyllabusCache =
      <String, Map<int, Map<String, dynamic>>>{};
  final Map<String, Map<String, _RecordedSessionMeta>>
  _recordedSessionMetaCache = <String, Map<String, _RecordedSessionMeta>>{};
  final Set<String> _progressRequestedClassIds = <String>{};
  final Set<String> _expandedClassIds = <String>{};
  List<Map<String, String>> get _teachers {
    final list = _teachersByUid.values.toList();
    list.sort((a, b) => (a["name"] ?? "").compareTo(b["name"] ?? ""));
    return list;
  }

  // ===== Search =====
  final TextEditingController _searchCtrl = TextEditingController();
  String _searchQuery = "";
  Timer? _searchDebounce;

  final TextEditingController _flexSearchCtrl = TextEditingController();
  String _flexSearch = "";
  String _flexStatusFilter = 'all';
  final Set<String> _expandedFlexKeys = <String>{};
  final Map<String, Future<_FlexCourseDetails>> _flexDetailsFutureByKey =
      <String, Future<_FlexCourseDetails>>{};
  final Map<String, List<Map<String, dynamic>>> _paymentsByUidCache =
      <String, List<Map<String, dynamic>>>{};

  // ===== Filters =====
  String _dayFilter = "All"; // "All" or one of week days
  bool? _openFilter; // null = all, true=open only, false=closed only

  static const List<String> _weekDays = <String>[
    "Sat",
    "Sun",
    "Mon",
    "Tue",
    "Wed",
    "Thu",
    "Fri",
  ];

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeOpenFromTimetable();
    });

    // IMPORTANT: load teachers first, then courses
    _bootFuture = _loadTeachers().then((_) => _loadCourses());
    _classesFuture = _classesRef.get();
    _loadAllLearners();

    _searchCtrl.addListener(() {
      _searchDebounce?.cancel();
      _searchDebounce = Timer(const Duration(milliseconds: 300), () {
        if (!mounted) return;
        setState(() => _searchQuery = _searchCtrl.text.trim().toLowerCase());
      });
    });

    _flexSearchCtrl.addListener(() {
      if (!mounted) return;
      setState(() => _flexSearch = _flexSearchCtrl.text.trim().toLowerCase());
    });
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    _flexSearchCtrl.dispose();
    super.dispose();
  }

  // -------------------- Notifications --------------------

  void _notify(String msg, {bool error = false}) {
    if (!mounted) return;
    AppToast.show(
      context,
      error ? humanizeUiMessage(msg) : msg,
      type: error ? AppToastType.error : AppToastType.info,
    );
  }

  // -------------------- Utilities --------------------

  String _formatDate(DateTime d) => DateFormat('yyyy-MM-dd').format(d);
  String _norm(String s) => s.trim().toLowerCase();
  static int _asInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString()) ?? 0;
  }

  static bool _asBool(dynamic v) {
    if (v is bool) return v;
    final s = (v ?? '').toString().trim().toLowerCase();
    return s == 'true' || s == '1';
  }

  bool _isLearnerRole(dynamic role) {
    final r = (role ?? "").toString().trim().toLowerCase();
    return r == "learner" || r == "learners" || r == "learner(s)";
  }

  List<Map<String, String>> _classLearnersList(Map<String, dynamic> cls) {
    final raw = cls['learners'];
    if (raw is! Map) return const <Map<String, String>>[];

    final out = <Map<String, String>>[];
    final learnersMap = Map<dynamic, dynamic>.from(raw);
    learnersMap.forEach((uid, learnerVal) {
      if (uid == null) return;
      final uidStr = uid.toString().trim();
      if (uidStr.isEmpty) return;
      String serial = '';
      String name = '';
      if (learnerVal is Map) {
        final m = learnerVal.map((k, v) => MapEntry(k.toString(), v));
        serial = (m['serial'] ?? '').toString().trim();
        name = (m['name'] ?? '').toString().trim();
      }
      out.add({'uid': uidStr, 'serial': serial, 'name': name});
    });

    out.sort((a, b) {
      final an = (a['name'] ?? '').toLowerCase();
      final bn = (b['name'] ?? '').toLowerCase();
      if (an.isNotEmpty || bn.isNotEmpty) return an.compareTo(bn);
      return (a['serial'] ?? '').compareTo(b['serial'] ?? '');
    });
    return out;
  }

  void _openLearnerFromClass(Map<String, String> learner) {
    final serial = (learner['serial'] ?? '').trim();
    final name = (learner['name'] ?? '').trim();
    final query = serial.isNotEmpty ? serial : name;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AdminLearnersScreen(initialSearch: query),
      ),
    );
  }

  bool _isTeacherRole(dynamic role) {
    final r = (role ?? "").toString().trim().toLowerCase();
    return r == "teacher" || r == "teachers" || r == "teacher(s)";
  }

  String _levelShort(String levelRaw) {
    final t = levelRaw.trim();
    if (t.isEmpty) return "CLS";
    return t.split(RegExp(r'\s+')).first;
  }

  String _normalizeVariantKey(String value) {
    return normalizeVariantKey(value);
  }

  String _normalizeStudyMode(String value) {
    return normalizeStudyMode(value);
  }

  String _variantLabel(String variantKey) {
    return variantLabel(_normalizeVariantKey(variantKey));
  }

  String _studyModeLabel(String studyMode) {
    return studyModeLabel(_normalizeStudyMode(studyMode));
  }

  String _classTypeLabel({
    required String variantKey,
    required String studyMode,
  }) {
    final v = _normalizeVariantKey(variantKey);
    final s = _normalizeStudyMode(studyMode);

    if (v == 'private') {
      final modeLabel = _studyModeLabel(s);
      if (modeLabel.trim().isNotEmpty) {
        return 'Private • $modeLabel';
      }
      return 'Private';
    }

    return _variantLabel(v);
  }

  bool _isScheduledClassType(String variantKey) {
    final v = _normalizeVariantKey(variantKey);
    return v == 'inclass' || v == 'private';
  }

  bool _isNonScheduledClassType(String variantKey) {
    return !_isScheduledClassType(variantKey);
  }

  // Short Class ID: exactly 5 chars (human-friendly)
  String _makeShortClassId() {
    const chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // avoid 0/O/1/I
    final rnd = Random.secure();
    return List.generate(5, (_) => chars[rnd.nextInt(chars.length)]).join();
  }

  Future<String> _generateUniqueClassId() async {
    String id = _makeShortClassId();
    for (int i = 0; i < 12; i++) {
      final snap = await _classesRef.child(id).get();
      if (!snap.exists) return id;
      id = _makeShortClassId();
    }
    return id; // best effort
  }

  // -------------------- Open from timetable --------------------

  Future<void> _maybeOpenFromTimetable() async {
    final id = widget.openClassId?.trim();
    if (id == null || id.isEmpty) return;

    try {
      await _bootFuture;

      final snap = await _classesRef.child(id).get();
      if (!snap.exists || snap.value is! Map) {
        _notify("Class not found: $id", error: true);
        return;
      }

      final cls = Map<String, dynamic>.from(snap.value as Map);
      cls["class_id"] = id;

      await _openClassEditor(existingClass: cls);
    } catch (e) {
      _notify("Failed to open class: $e", error: true);
    }
  }

  // -------------------- Load ALL teachers --------------------

  Future<void> _loadTeachers() async {
    if (mounted) setState(() => _loadingTeachers = true);

    try {
      final snap = await _usersRef.get();
      if (!mounted) return;

      final Map<String, Map<String, String>> byUid = {};
      final Map<String, String> uidByName = {};

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

          byUid[uid] = teacher;
          if (full.isNotEmpty) uidByName[_norm(full)] = uid;
        }
      }

      if (!mounted) return;
      setState(() {
        _teachersByUid = byUid;
        _teacherUidByName = uidByName;
        _loadingTeachers = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingTeachers = false);
      _notify("Failed to load teachers: $e", error: true);
    }
  }

  // -------------------- Load courses --------------------

  Future<void> _loadCourses() async {
    if (mounted) setState(() => _loadingCourses = true);

    try {
      final snap = await _coursesRef.get();
      if (!mounted) return;

      final List<Map<String, dynamic>> list = [];

      if (snap.exists && snap.value is Map) {
        final map = Map<dynamic, dynamic>.from(snap.value as Map);

        for (final entry in map.entries) {
          final id = entry.key.toString();
          final raw = entry.value;
          if (raw is! Map) continue;

          final data = Map<String, dynamic>.from(raw);
          final levelRaw = (data["level"] ?? "").toString();

          // instructors can be LIST (old) or MAP (new) — keep ONLY teachers
          final insRaw = data["instructors"];
          final List<Map<String, String>> instructorsList = [];

          if (insRaw is List) {
            for (final item in insRaw) {
              final name = (item ?? "").toString().trim();
              if (name.isEmpty) continue;

              final uid = _teacherUidByName[_norm(name)];
              if (uid == null) continue;

              final t = _teachersByUid[uid];
              if (t == null) continue;

              instructorsList.add({
                "uid": t["uid"] ?? uid,
                "name": t["name"] ?? name,
                "serial": t["serial"] ?? "",
              });
            }
          } else if (insRaw is Map) {
            final m = Map<dynamic, dynamic>.from(insRaw);
            m.forEach((k, v) {
              final uid = k.toString();
              final t = _teachersByUid[uid];
              if (t == null) return;
              instructorsList.add({
                "uid": t["uid"] ?? uid,
                "name": t["name"] ?? "",
                "serial": t["serial"] ?? "",
              });
            });
          }

          instructorsList.sort(
            (a, b) => (a["name"] ?? "").compareTo(b["name"] ?? ""),
          );

          list.add({
            "id": id,
            "title": (data["title"] ?? "").toString(),
            "course_code": (data["course_code"] ?? "").toString(),
            "duration": (data["duration"] ?? "").toString(),
            "category": (data["category"] ?? "").toString(),
            "level": _levelShort(levelRaw),
            "instructors": instructorsList,
          });
        }

        list.sort(
          (a, b) => (a["course_code"] as String).compareTo(
            b["course_code"] as String,
          ),
        );
      }

      if (!mounted) return;
      setState(() {
        _courses = list;
        _loadingCourses = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingCourses = false);
      _notify("Failed to load courses: $e", error: true);
    }
  }

  // -------------------- Load ALL learners --------------------

  Future<void> _loadAllLearners() async {
    if (mounted) setState(() => _loadingLearners = true);

    try {
      final snap = await _usersRef.get();
      if (!mounted) return;

      final List<Map<String, dynamic>> list = [];

      if (snap.exists && snap.value is Map) {
        final all = Map<dynamic, dynamic>.from(snap.value as Map);

        for (final entry in all.entries) {
          final uid = entry.key.toString();
          final raw = entry.value;
          if (raw is! Map) continue;

          final data = Map<String, dynamic>.from(raw);
          if (!_isLearnerRole(data["role"])) continue;

          final serial = (data["serial"] ?? "").toString().trim();
          final first = (data["first_name"] ?? "").toString().trim();
          final last = (data["last_name"] ?? "").toString().trim();
          final name = "$first $last".trim();

          final coursesMap = (data["courses"] is Map)
              ? Map<String, dynamic>.from(
                  (data["courses"] as Map).map(
                    (k, v) => MapEntry(
                      k.toString(),
                      v is Map ? Map<String, dynamic>.from(v) : v,
                    ),
                  ),
                )
              : <String, dynamic>{};

          list.add({
            "uid": uid,
            "serial": serial.isEmpty ? "N/A" : serial,
            "name": name.isEmpty ? "Unnamed" : name,
            "courses": coursesMap,
          });
        }
      }

      list.sort((a, b) => (a["name"] as String).compareTo(b["name"] as String));

      if (!mounted) return;
      setState(() {
        _allLearners = list;
        _loadingLearners = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingLearners = false);
      _notify("Failed to load learners: $e", error: true);
    }
  }

  // -------------------- Learner / course helpers --------------------

  Set<String> _uidsWhoHaveCourse(String courseId) {
    final set = <String>{};
    for (final l in _allLearners) {
      final courses = (l["courses"] is Map)
          ? Map<String, dynamic>.from(l["courses"] as Map)
          : <String, dynamic>{};

      bool has = false;
      for (final e in courses.entries) {
        final m = (e.value is Map)
            ? Map<String, dynamic>.from(e.value)
            : <String, dynamic>{};
        if ((m["id"] ?? "").toString() == courseId) {
          has = true;
          break;
        }
      }

      if (has) set.add(l["uid"].toString());
    }
    return set;
  }

  Set<String> _uidsWhoMatchCourseVariant({
    required String courseId,
    required String variantKey,
    required String studyMode,
    String? currentClassId,
  }) {
    final wantedVariant = _normalizeVariantKey(variantKey);
    final wantedStudyMode = _normalizeStudyMode(studyMode);

    final set = <String>{};

    for (final l in _allLearners) {
      final courses = (l["courses"] is Map)
          ? Map<String, dynamic>.from(l["courses"] as Map)
          : <String, dynamic>{};

      bool hasMatch = false;

      for (final e in courses.entries) {
        final m = (e.value is Map)
            ? Map<String, dynamic>.from(e.value)
            : <String, dynamic>{};

        final enrolledCourseId = (m["id"] ?? "").toString().trim();
        if (enrolledCourseId != courseId) continue;

        // ✅ Migration fallback:
        // if this learner course is already linked to the same class,
        // treat it as enrolled even if the old class node has old/missing variant data.
        final linkedClassMap = (m["class"] is Map)
            ? Map<String, dynamic>.from(m["class"] as Map)
            : <String, dynamic>{};

        final linkedClassId = (linkedClassMap["class_id"] ?? "")
            .toString()
            .trim();

        if (currentClassId != null &&
            currentClassId.trim().isNotEmpty &&
            linkedClassId == currentClassId.trim()) {
          hasMatch = true;
          break;
        }

        final enrolledVariant = _normalizeVariantKey(
          (m["variantKey"] ?? m["variant"] ?? m["deliveryKey"] ?? "")
              .toString(),
        );

        final enrolledStudyMode = _normalizeStudyMode(
          (m["studyMode"] ?? "").toString(),
        );

        if (wantedVariant != enrolledVariant) {
          continue;
        }

        if (wantedVariant == 'private') {
          if (wantedStudyMode != enrolledStudyMode) {
            continue;
          }
        }

        hasMatch = true;
        break;
      }

      if (hasMatch) {
        set.add(l["uid"].toString());
      }
    }

    return set;
  }

  Future<void> _syncLearnersClassDataStrict({
    required String courseId,
    required Map<String, dynamic> classPayload,
    required Map<String, dynamic> selectedLearnersByUid,
    required Map<String, dynamic> previousLearnersByUid,
  }) async {
    final classId = (classPayload["class_id"] ?? "").toString();
    final status = (classPayload["status"] ?? "active").toString();

    // removed learners => remove class field
    final removedUids = previousLearnersByUid.keys
        .where((uid) => !selectedLearnersByUid.containsKey(uid))
        .toList();

    for (final uid in removedUids) {
      final userSnap = await _usersRef.child(uid).get();
      if (!userSnap.exists || userSnap.value is! Map) continue;

      final userData = Map<String, dynamic>.from(userSnap.value as Map);
      final courses = (userData["courses"] is Map)
          ? Map<dynamic, dynamic>.from(userData["courses"])
          : <dynamic, dynamic>{};

      String? courseKey;
      for (final entry in courses.entries) {
        final m = (entry.value is Map)
            ? Map<String, dynamic>.from(entry.value)
            : <String, dynamic>{};
        if ((m["id"] ?? "").toString() == courseId) {
          courseKey = entry.key.toString();
          break;
        }
      }
      if (courseKey == null) continue;

      await _usersRef
          .child(uid)
          .child("courses")
          .child(courseKey)
          .child("class")
          .remove();
    }

    // kept/added learners => set class field (only if enrolled)
    for (final uid in selectedLearnersByUid.keys) {
      final userSnap = await _usersRef.child(uid).get();
      if (!userSnap.exists || userSnap.value is! Map) continue;

      final userData = Map<String, dynamic>.from(userSnap.value as Map);
      final courses = (userData["courses"] is Map)
          ? Map<dynamic, dynamic>.from(userData["courses"])
          : <dynamic, dynamic>{};

      String? courseKey;
      for (final entry in courses.entries) {
        final m = (entry.value is Map)
            ? Map<String, dynamic>.from(entry.value)
            : <String, dynamic>{};
        if ((m["id"] ?? "").toString() == courseId) {
          courseKey = entry.key.toString();
          break;
        }
      }
      if (courseKey == null) continue;

      final clsMini = {
        "class_id": classId,
        "course_id": courseId,
        "course_code": (classPayload["course_code"] ?? "").toString(),
        "course_title": (classPayload["course_title"] ?? "").toString(),
        "variantKey": (classPayload["variantKey"] ?? "").toString(),
        "variantLabel": (classPayload["variantLabel"] ?? "").toString(),
        "studyMode": (classPayload["studyMode"] ?? "").toString(),
        "studyModeLabel": (classPayload["studyModeLabel"] ?? "").toString(),
        "instructor": (classPayload["instructor"] ?? "").toString(),
        "status": status,
        "updatedAt": ServerValue.timestamp,
      };

      await _usersRef
          .child(uid)
          .child("courses")
          .child(courseKey)
          .child("class")
          .set(clsMini);
    }
  }

  // -------------------- Class actions --------------------

  Future<void> _setClassStatus(String classId, String status) async {
    try {
      await _classesRef.child(classId).update({
        "status": status,
        "updated_at": ServerValue.timestamp,
      });
      _notify("Updated $classId → $status");
    } catch (e) {
      _notify("Failed to update: $e", error: true);
    }
  }

  Future<void> _deleteClass(String classId) async {
    final ok = await showDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (_) => AlertDialog(
        title: const Text("Delete class?"),
        content: Text("This will permanently delete:\n$classId"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("Cancel"),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text("Delete"),
          ),
        ],
      ),
    );

    if (ok != true) return;

    try {
      final clsSnap = await _classesRef.child(classId).get();
      if (clsSnap.exists && clsSnap.value is Map) {
        final cls = Map<String, dynamic>.from(clsSnap.value as Map);
        final courseId = (cls["course_id"] ?? "").toString();

        final prevLearners = (cls["learners"] is Map)
            ? Map<String, dynamic>.from(
                (cls["learners"] as Map).map(
                  (k, v) => MapEntry(k.toString(), v),
                ),
              )
            : <String, dynamic>{};

        await _syncLearnersClassDataStrict(
          courseId: courseId,
          classPayload: {"class_id": classId, "course_id": courseId},
          selectedLearnersByUid: const <String, dynamic>{},
          previousLearnersByUid: prevLearners,
        );
      }

      await _classesRef.child(classId).remove();
      _notify("Deleted: $classId");
    } catch (e) {
      _notify("Failed to delete: $e", error: true);
    }
  }

  // -------------------- Filters / Search helpers --------------------

  bool _matchesDayFilter(Map<String, dynamic> cls) {
    if (_dayFilter == "All") return true;

    final sched = (cls["schedule"] is Map)
        ? Map<String, dynamic>.from(cls["schedule"])
        : <String, dynamic>{};
    final sessions = (sched["sessions"] is List)
        ? List<dynamic>.from(sched["sessions"])
        : <dynamic>[];
    if (sessions.isEmpty) return false;

    for (final s in sessions) {
      final m = (s is Map) ? Map<String, dynamic>.from(s) : <String, dynamic>{};
      final day = (m["day"] ?? "").toString().trim();
      if (day == _dayFilter) return true;
    }
    return false;
  }

  bool _matchesOpenFilter(Map<String, dynamic> cls) {
    if (_openFilter == null) return true;
    final isOpen = (cls["is_open"] ?? true) == true;
    return _openFilter == isOpen;
  }

  bool _matchesSearch(Map<String, dynamic> cls) {
    if (_searchQuery.isEmpty) return true;

    final id = (cls["class_id"] ?? "").toString().toLowerCase();
    final title = (cls["course_title"] ?? "").toString().toLowerCase();
    final level = (cls["course_level"] ?? "").toString().toLowerCase();
    final courseId = (cls["course_id"] ?? "").toString().toLowerCase();
    final inst = (cls["instructor"] ?? "").toString().toLowerCase();
    final status = (cls["status"] ?? "").toString().toLowerCase();

    bool hit =
        id.contains(_searchQuery) ||
        title.contains(_searchQuery) ||
        level.contains(_searchQuery) ||
        courseId.contains(_searchQuery) ||
        inst.contains(_searchQuery) ||
        status.contains(_searchQuery);

    if (hit) return true;

    // ✅ Search by learners (name / serial) inside cls["learners"]
    final learners = (cls["learners"] is Map)
        ? Map<dynamic, dynamic>.from(cls["learners"])
        : null;
    if (learners == null || learners.isEmpty) return false;

    for (final entry in learners.entries) {
      final v = entry.value;
      if (v is Map) {
        final m = Map<String, dynamic>.from(v);
        final name = (m["name"] ?? "").toString().toLowerCase();
        final serial = (m["serial"] ?? "").toString().toLowerCase();
        if (name.contains(_searchQuery) || serial.contains(_searchQuery))
          return true;
      }
    }

    return false;
  }

  Color _statusColor(String status) {
    switch (status) {
      case "paused":
        return Colors.orange;
      case "blocked":
        return Colors.red;
      default:
        return Colors.green;
    }
  }

  // Cleaner schedule line: "Sat 10:00 (90m) • Tue 18:00 (60m)"

  String _prettySessions(Map<String, dynamic> cls) {
    final variantKey = (cls["variantKey"] ?? "").toString();
    final sched = (cls["schedule"] is Map)
        ? Map<String, dynamic>.from(cls["schedule"])
        : <String, dynamic>{};
    final sessions = (sched["sessions"] is List)
        ? List<dynamic>.from(sched["sessions"])
        : <dynamic>[];

    if (sessions.isEmpty) {
      final v = _normalizeVariantKey(variantKey);

      if (v == 'flexible') return "Flexible schedule";
      if (v == 'recorded') return "On-demand access";

      return "No schedule";
    }

    final parts = sessions.map((s) {
      final m = (s is Map) ? Map<String, dynamic>.from(s) : <String, dynamic>{};
      final day = (m["day"] ?? "").toString().trim();
      final time = (m["start_time"] ?? "").toString().trim();
      final dur = (m["duration_min"] ?? "").toString().trim();
      final dd = day.isEmpty ? "Day" : day;
      final tt = time.isEmpty ? "--:--" : time;
      final du = dur.isEmpty ? "?" : dur;
      return "$dd $tt (${du}m)";
    }).toList();

    return parts.join(" • ");
  }

  Widget _pill({required String text, required Color color}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w900,
          fontSize: 11,
        ),
      ),
    );
  }

  Color _openColor(bool isOpen) => isOpen ? Colors.blue : Colors.grey;

  // -------------------- Learner Picker (STRICT ENROLLMENT) --------------------
  Future<void> _openLearnersPickerStrict({
    required String currentClassId,
    required String selectedCourseId,
    required String selectedVariantKey,
    required String selectedStudyMode,
    required Map<String, dynamic> selectedLearnersByUid,
    required StateSetter setModalState,
  }) async {
    // ✅ Always refresh learners before opening the picker,
    // so recently changed enrollments are detected.
    await _loadAllLearners();

    if (_loadingLearners) {
      _notify("Learners are still loading...");
      return;
    }

    final enrolledUids = _uidsWhoMatchCourseVariant(
      courseId: selectedCourseId,
      variantKey: selectedVariantKey,
      studyMode: selectedStudyMode,
      currentClassId: currentClassId,
    );
    String q = "";
    Timer? pickerSearchDebounce;

    await showDialog(
      context: context,
      useRootNavigator: true,
      builder: (_) {
        return StatefulBuilder(
          builder: (context, setDState) {
            final filtered = _allLearners.where((l) {
              if (q.isEmpty) return true;
              final serial = (l["serial"] ?? "").toString().toLowerCase();
              final name = (l["name"] ?? "").toString().toLowerCase();
              return serial.contains(q) || name.contains(q);
            }).toList();

            // ✅ ORDER: Enrolled first, then Not enrolled. (Optional: selected first inside each group)
            filtered.sort((a, b) {
              final auid = a["uid"].toString();
              final buid = b["uid"].toString();

              final aEnrolled = enrolledUids.contains(auid);
              final bEnrolled = enrolledUids.contains(buid);

              if (aEnrolled != bEnrolled) return aEnrolled ? -1 : 1;

              final aSelected = selectedLearnersByUid.containsKey(auid);
              final bSelected = selectedLearnersByUid.containsKey(buid);

              if (aSelected != bSelected) return aSelected ? -1 : 1;

              final an = (a["name"] ?? "").toString();
              final bn = (b["name"] ?? "").toString();
              return an.compareTo(bn);
            });

            return AlertDialog(
              title: const Text("Pick learners"),
              content: SizedBox(
                width: double.maxFinite,
                height: 460,
                child: Column(
                  children: [
                    TextField(
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        hintText: "Search by name or serial",
                      ),
                      onChanged: (v) {
                        pickerSearchDebounce?.cancel();
                        pickerSearchDebounce = Timer(
                          const Duration(milliseconds: 250),
                          () {
                            if (!context.mounted) return;
                            setDState(() => q = v.trim().toLowerCase());
                          },
                        );
                      },
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: ListView.builder(
                        itemCount: filtered.length,
                        itemBuilder: (_, i) {
                          final l = filtered[i];
                          final uid = l["uid"].toString();
                          final serial = l["serial"].toString();
                          final name = l["name"].toString();

                          final isEnrolled = enrolledUids.contains(uid);
                          final isSelected = selectedLearnersByUid.containsKey(
                            uid,
                          );

                          return CheckboxListTile(
                            value: isSelected,
                            onChanged: (val) {
                              // ✅ FIX:
                              // - Block ONLY when trying to tick ON while not enrolled.
                              // - Always allow untick OFF (so you can remove if they got unenrolled later).
                              if (val == true && !isEnrolled) {
                                _notify(
                                  "Not enrolled in this course. Assign course first.",
                                  error: true,
                                );
                                return;
                              }

                              setDState(() {
                                if (val == true) {
                                  selectedLearnersByUid[uid] = {
                                    "serial": serial,
                                    "name": name,
                                  };
                                } else {
                                  selectedLearnersByUid.remove(uid);
                                }
                              });
                              setModalState(() {});

                              // ✅ Popup notification (shows even above the dialog)
                              if (val == true) {
                                _notify("Added: $name");
                              } else {
                                _notify("Removed: $name");
                              }
                            },
                            title: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                Container(
                                  margin: const EdgeInsets.only(left: 8),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(999),
                                    color: isEnrolled
                                        ? Colors.blue.withValues(alpha: 0.12)
                                        : Colors.orange.withValues(alpha: 0.12),
                                    border: Border.all(
                                      color: isEnrolled
                                          ? Colors.blue.withValues(alpha: 0.35)
                                          : Colors.orange.withValues(
                                              alpha: 0.35,
                                            ),
                                    ),
                                  ),
                                  child: Text(
                                    isEnrolled ? "Enrolled" : "Not enrolled",
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w900,
                                      color: isEnrolled
                                          ? Colors.blue
                                          : Colors.orange.shade800,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            subtitle: Text("Serial: $serial"),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text("Done"),
                ),
              ],
            );
          },
        );
      },
    );

    pickerSearchDebounce?.cancel();
  }

  // -------------------- Full Create/Edit Bottom Sheet --------------------

  Future<void> _openClassEditor({Map<String, dynamic>? existingClass}) async {
    if (_loadingCourses) return _notify("Courses are still loading...");
    if (_courses.isEmpty) return _notify("No courses found.", error: true);

    if (_loadingTeachers) return _notify("Teachers are still loading...");
    if (_teachers.isEmpty) return _notify("No teachers found.", error: true);

    final bool isEdit = existingClass != null;

    final String classId = isEdit
        ? (existingClass["class_id"] ?? "").toString()
        : await _generateUniqueClassId();

    Map<String, dynamic> selectedCourse = _courses.first;
    if (isEdit) {
      final courseId = (existingClass["course_id"] ?? "").toString();
      final found = _courses.where((c) => c["id"] == courseId).toList();
      if (found.isNotEmpty) selectedCourse = found.first;
    }
    String selectedVariantKey = isEdit
        ? _normalizeVariantKey((existingClass["variantKey"] ?? "").toString())
        : "inclass";

    String selectedStudyMode = isEdit
        ? _normalizeStudyMode((existingClass["studyMode"] ?? "").toString())
        : "";

    if (selectedVariantKey.isEmpty) {
      selectedVariantKey = "inclass";
    }

    bool isOpen = isEdit ? ((existingClass["is_open"] ?? true) == true) : true;

    // Instructors from teachers list
    List<Map<String, String>> instructors = List<Map<String, String>>.from(
      _teachers,
    );
    String instKey(Map<String, String> t) => (t["uid"] ?? "").trim();

    Map<String, String>? selectedInstructorObj = instructors.isNotEmpty
        ? instructors.first
        : null;

    if (isEdit) {
      final cur = existingClass["instructor_current"];
      if (cur is Map) {
        final curMap = Map<String, dynamic>.from(cur);
        final curUid = (curMap["uid"] ?? "").toString().trim();
        final curName = (curMap["name"] ?? "").toString().trim().toLowerCase();

        if (curUid.isNotEmpty) {
          final found = instructors
              .where((t) => (t["uid"] ?? "") == curUid)
              .toList();
          if (found.isNotEmpty) selectedInstructorObj = found.first;
        }

        if ((selectedInstructorObj == null ||
                instKey(selectedInstructorObj).isEmpty) &&
            curName.isNotEmpty) {
          final found = instructors
              .where(
                (t) =>
                    (t["name"] ?? "").toString().trim().toLowerCase() ==
                    curName,
              )
              .toList();
          if (found.isNotEmpty) selectedInstructorObj = found.first;
        }
      } else {
        final exName = (existingClass["instructor"] ?? "")
            .toString()
            .trim()
            .toLowerCase();
        if (exName.isNotEmpty) {
          final found = instructors
              .where(
                (t) =>
                    (t["name"] ?? "").toString().trim().toLowerCase() == exName,
              )
              .toList();
          if (found.isNotEmpty) selectedInstructorObj = found.first;
        }
      }
    }

    final String status = isEdit
        ? (existingClass["status"] ?? "active").toString()
        : "active";

    final schedule = (isEdit && existingClass["schedule"] is Map)
        ? Map<String, dynamic>.from(existingClass["schedule"])
        : <String, dynamic>{};

    final sessionsCountCtrl = TextEditingController(
      text: isEdit ? (schedule["sessions_count"] ?? "12").toString() : "12",
    );

    DateTime? firstSessionDate;
    if (isEdit) {
      final first = (schedule["first_session_date"] ?? "").toString();
      if (first.isNotEmpty) {
        try {
          firstSessionDate = DateTime.parse(first);
        } catch (_) {}
      }
    }

    final List<_ScheduleRow> scheduleRows = [];
    if (isEdit && schedule["sessions"] is List) {
      final list = List<dynamic>.from(schedule["sessions"]);
      for (final item in list) {
        final m = (item is Map)
            ? Map<String, dynamic>.from(item)
            : <String, dynamic>{};
        final row = _ScheduleRow(day: (m["day"] ?? "Mon").toString());
        row.startTime = (m["start_time"] ?? "").toString().isEmpty
            ? null
            : (m["start_time"] ?? "").toString();
        row.durationCtrl.text = (m["duration_min"] ?? "90").toString();
        scheduleRows.add(row);
      }
    }
    if (scheduleRows.isEmpty) {
      scheduleRows.add(_ScheduleRow(day: "Sat"));
      scheduleRows.add(_ScheduleRow(day: "Tue"));
    }

    Map<String, dynamic> previousLearnersByUid = {};
    Map<String, dynamic> selectedLearnersByUid = {};

    if (isEdit && existingClass["learners"] is Map) {
      previousLearnersByUid = Map<String, dynamic>.from(
        (existingClass["learners"] as Map).map(
          (k, v) => MapEntry(k.toString(), v),
        ),
      );
      selectedLearnersByUid = Map<String, dynamic>.from(previousLearnersByUid);
    }

    Future<void> pickDate(StateSetter setModalState) async {
      final now = DateTime.now();
      final picked = await showDatePicker(
        context: context,
        useRootNavigator: true,
        firstDate: DateTime(now.year - 1),
        lastDate: DateTime(now.year + 3),
        initialDate: firstSessionDate ?? now,
      );
      if (picked != null) setModalState(() => firstSessionDate = picked);
    }

    Future<void> pickTime(StateSetter setModalState, _ScheduleRow row) async {
      final picked = await showTimePicker(
        context: context,
        useRootNavigator: true,
        initialTime: TimeOfDay.now(),
      );
      if (picked != null) {
        final hh = picked.hour.toString().padLeft(2, '0');
        final mm = picked.minute.toString().padLeft(2, '0');
        setModalState(() => row.startTime = "$hh:$mm");
      }
    }

    bool saving = false;

    final sheetFuture = showModalBottomSheet(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      enableDrag: false,
      isDismissible: false,
      showDragHandle: false,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            void setSaving(bool v) {
              saving = v;
              setModalState(() {});
            }

            final bool requiresFixedSchedule = _isScheduledClassType(
              selectedVariantKey,
            );
            final learnersCount = selectedLearnersByUid.length;
            final courseId = selectedCourse["id"].toString();

            final courseTitle = (selectedCourse["title"] ?? "").toString();
            final courseLevel = (selectedCourse["level"] ?? "").toString();

            return SafeArea(
              child: Padding(
                padding: EdgeInsets.only(
                  left: 16,
                  right: 16,
                  top: 10,
                  bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              isEdit ? "Edit class" : "Add class",
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w900,
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
                              color: Colors.black.withValues(alpha: 0.06),
                            ),
                            child: Text(
                              "ID: $classId",
                              style: const TextStyle(
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),

                      if (isEdit)
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: Colors.grey.withValues(alpha: 0.35),
                            ),
                            color: Colors.grey.withValues(alpha: 0.06),
                          ),
                          child: Text(
                            // ✅ Removed course_code in preview
                            "${courseLevel.isEmpty ? "" : "$courseLevel  "} ${courseTitle.isEmpty ? "-" : courseTitle}"
                                .trim(),
                            style: const TextStyle(fontWeight: FontWeight.w800),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        )
                      else
                        DropdownButtonFormField<Map<String, dynamic>>(
                          isExpanded: true,
                          initialValue: selectedCourse,
                          decoration: const InputDecoration(
                            labelText: "Course",
                            border: OutlineInputBorder(),
                          ),
                          selectedItemBuilder: (context) {
                            return _courses.map((c) {
                              final lv = (c["level"] ?? "").toString();
                              final tt = (c["title"] ?? "").toString();
                              final label = "${lv.isEmpty ? "" : "$lv  "}$tt"
                                  .trim();
                              return Align(
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              );
                            }).toList();
                          },
                          items: _courses.map((c) {
                            final lv = (c["level"] ?? "").toString();
                            final tt = (c["title"] ?? "").toString();
                            final label = "${lv.isEmpty ? "" : "$lv  "}$tt"
                                .trim();
                            return DropdownMenuItem<Map<String, dynamic>>(
                              value: c,
                              child: SizedBox(
                                width: double.infinity,
                                child: Text(
                                  label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            );
                          }).toList(),
                          onChanged: saving
                              ? null
                              : (val) {
                                  if (val == null) return;
                                  setModalState(() {
                                    selectedCourse = val;
                                    instructors =
                                        List<Map<String, String>>.from(
                                          _teachers,
                                        );
                                    selectedInstructorObj =
                                        instructors.isNotEmpty
                                        ? instructors.first
                                        : null;
                                    selectedLearnersByUid.clear();
                                  });
                                },
                        ),

                      const SizedBox(height: 12),

                      DropdownButtonFormField<String>(
                        isExpanded: true,
                        initialValue: selectedInstructorObj == null
                            ? null
                            : instKey(selectedInstructorObj!),
                        decoration: const InputDecoration(
                          labelText: "Instructor",
                          border: OutlineInputBorder(),
                        ),
                        items: instructors.map((t) {
                          final uid = (t["uid"] ?? "").toString();
                          final name = (t["name"] ?? "").toString();
                          final serial = (t["serial"] ?? "").toString();
                          return DropdownMenuItem<String>(
                            value: uid,
                            child: Text(
                              "$name${serial.isEmpty ? "" : " ($serial)"}",
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          );
                        }).toList(),
                        onChanged: saving
                            ? null
                            : (uid) {
                                final t = instructors.firstWhere(
                                  (x) => (x["uid"] ?? "") == (uid ?? ""),
                                  orElse: () => {
                                    "uid": "",
                                    "name": "",
                                    "serial": "",
                                  },
                                );
                                setModalState(() => selectedInstructorObj = t);
                              },
                      ),

                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        initialValue: selectedVariantKey,
                        decoration: const InputDecoration(
                          labelText: "Class type",
                          border: OutlineInputBorder(),
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'inclass',
                            child: Text('In-Class'),
                          ),
                          DropdownMenuItem(
                            value: 'flexible',
                            child: Text('Flexible'),
                          ),
                          DropdownMenuItem(
                            value: 'private',
                            child: Text('Private'),
                          ),
                          DropdownMenuItem(
                            value: 'recorded',
                            child: Text('Recorded'),
                          ),
                        ],
                        onChanged: saving
                            ? null
                            : (v) {
                                if (v == null) return;
                                setModalState(() {
                                  selectedVariantKey = _normalizeVariantKey(v);

                                  if (selectedVariantKey != 'private') {
                                    selectedStudyMode = '';
                                  } else if (selectedStudyMode.isEmpty) {
                                    selectedStudyMode = 'online';
                                  }

                                  selectedLearnersByUid.clear();
                                });
                              },
                      ),

                      if (selectedVariantKey == 'private') ...[
                        const SizedBox(height: 12),
                        DropdownButtonFormField<String>(
                          initialValue: selectedStudyMode.isEmpty
                              ? 'online'
                              : selectedStudyMode,
                          decoration: const InputDecoration(
                            labelText: "Private mode",
                            border: OutlineInputBorder(),
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: 'online',
                              child: Text('Online'),
                            ),
                            DropdownMenuItem(
                              value: 'inclass',
                              child: Text('In-Class'),
                            ),
                          ],
                          onChanged: saving
                              ? null
                              : (v) {
                                  if (v == null) return;
                                  setModalState(() {
                                    selectedStudyMode = _normalizeStudyMode(v);
                                    selectedLearnersByUid.clear();
                                  });
                                },
                        ),
                      ],
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Colors.grey.withValues(alpha: 0.35),
                          ),
                          color: Colors.grey.withValues(alpha: 0.06),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                isOpen ? "Class is OPEN" : "Class is CLOSED",
                                style: const TextStyle(
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ),
                            Switch(
                              value: isOpen,
                              onChanged: saving
                                  ? null
                                  : (v) => setModalState(() => isOpen = v),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 12),

                      TextField(
                        controller: sessionsCountCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: "Number of sessions",
                          border: OutlineInputBorder(),
                        ),
                        enabled: !saving,
                      ),

                      const SizedBox(height: 12),

                      if (requiresFixedSchedule) ...[
                        OutlinedButton.icon(
                          onPressed: saving
                              ? null
                              : () => pickDate(setModalState),
                          icon: const Icon(Icons.event),
                          label: Text(
                            firstSessionDate == null
                                ? "Pick first session date"
                                : "First session: ${_formatDate(firstSessionDate!)}",
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],

                      OutlinedButton.icon(
                        onPressed: saving
                            ? null
                            : (!isOpen
                                  ? null
                                  : () => _openLearnersPickerStrict(
                                      currentClassId: classId,
                                      selectedCourseId: courseId,
                                      selectedVariantKey: selectedVariantKey,
                                      selectedStudyMode: selectedStudyMode,
                                      selectedLearnersByUid:
                                          selectedLearnersByUid,
                                      setModalState: setModalState,
                                    )),
                        icon: const Icon(Icons.people_alt_rounded),
                        label: Text(
                          _loadingLearners
                              ? "Loading learners..."
                              : isOpen
                              ? (learnersCount == 0
                                    ? "Pick learners"
                                    : "Learners selected: $learnersCount")
                              : (learnersCount == 0
                                    ? "Learners (Closed)"
                                    : "Learners: $learnersCount (Closed)"),
                        ),
                      ),

                      if (requiresFixedSchedule) ...[
                        const SizedBox(height: 16),
                        const Text(
                          "Weekly schedule",
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 8),

                        ...scheduleRows.map((row) {
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Row(
                              children: [
                                SizedBox(
                                  width: 110,
                                  child: InputDecorator(
                                    decoration: const InputDecoration(
                                      labelText: "Day",
                                      border: OutlineInputBorder(),
                                      isDense: true,
                                      contentPadding: EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 10,
                                      ),
                                    ),
                                    child: DropdownButtonHideUnderline(
                                      child: DropdownButton<String>(
                                        value: _weekDays.contains(row.day)
                                            ? row.day
                                            : "Mon",
                                        isExpanded: true,
                                        items: _weekDays
                                            .map(
                                              (d) => DropdownMenuItem<String>(
                                                value: d,
                                                child: Text(
                                                  d,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    fontWeight: FontWeight.w800,
                                                  ),
                                                ),
                                              ),
                                            )
                                            .toList(),
                                        onChanged: saving
                                            ? null
                                            : (v) {
                                                if (v == null) return;
                                                setModalState(
                                                  () => row.day = v,
                                                );
                                              },
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: OutlinedButton(
                                    onPressed: saving
                                        ? null
                                        : () => pickTime(setModalState, row),
                                    child: Text(
                                      row.startTime == null
                                          ? "Start time"
                                          : row.startTime!,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                SizedBox(
                                  width: 120,
                                  child: TextField(
                                    controller: row.durationCtrl,
                                    keyboardType: TextInputType.number,
                                    decoration: const InputDecoration(
                                      labelText: "Minutes",
                                      border: OutlineInputBorder(),
                                      isDense: true,
                                      contentPadding: EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 10,
                                      ),
                                    ),
                                    enabled: !saving,
                                  ),
                                ),
                                IconButton(
                                  tooltip: "Remove",
                                  onPressed: saving
                                      ? null
                                      : () {
                                          if (scheduleRows.length <= 1) return;
                                          setModalState(
                                            () => scheduleRows.remove(row),
                                          );
                                        },
                                  icon: const Icon(Icons.close),
                                ),
                              ],
                            ),
                          );
                        }),

                        OutlinedButton.icon(
                          onPressed: saving
                              ? null
                              : () => setModalState(
                                  () => scheduleRows.add(
                                    _ScheduleRow(day: "Mon"),
                                  ),
                                ),
                          icon: const Icon(Icons.add),
                          label: const Text("Add another day"),
                        ),
                      ],

                      const SizedBox(height: 18),

                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: saving
                              ? null
                              : () async {
                                  final pickedUid =
                                      (selectedInstructorObj?["uid"] ?? "")
                                          .trim();
                                  final pickedName =
                                      (selectedInstructorObj?["name"] ?? "")
                                          .trim();

                                  if (pickedUid.isEmpty || pickedName.isEmpty) {
                                    return _notify(
                                      "Pick an instructor.",
                                      error: true,
                                    );
                                  }

                                  final sessionsCount = int.tryParse(
                                    sessionsCountCtrl.text.trim(),
                                  );
                                  if (sessionsCount == null ||
                                      sessionsCount <= 0) {
                                    return _notify(
                                      "Sessions count invalid.",
                                      error: true,
                                    );
                                  }

                                  if (requiresFixedSchedule &&
                                      firstSessionDate == null) {
                                    return _notify(
                                      "Pick the first session date.",
                                      error: true,
                                    );
                                  }

                                  final sessions = <Map<String, dynamic>>[];

                                  if (requiresFixedSchedule) {
                                    for (final row in scheduleRows) {
                                      if (row.startTime == null) {
                                        return _notify(
                                          "Pick start time for ${row.day}.",
                                          error: true,
                                        );
                                      }
                                      final dur = int.tryParse(
                                        row.durationCtrl.text.trim(),
                                      );
                                      if (dur == null || dur <= 0) {
                                        return _notify(
                                          "Duration invalid for ${row.day}.",
                                          error: true,
                                        );
                                      }
                                      sessions.add({
                                        "day": row.day,
                                        "start_time": row.startTime,
                                        "duration_min": dur,
                                      });
                                    }
                                  }

                                  final courseId = selectedCourse["id"]
                                      .toString();

                                  // ✅ FIX (so you NEVER get stuck):
                                  // Auto-remove selected learners who are no longer enrolled.
                                  final enrolledUids =
                                      _uidsWhoMatchCourseVariant(
                                        courseId: courseId,
                                        variantKey: selectedVariantKey,
                                        studyMode: selectedStudyMode,
                                      );
                                  final removedAuto = <String>[];
                                  final selectedUids = selectedLearnersByUid
                                      .keys
                                      .toList();
                                  for (final uid in selectedUids) {
                                    if (!enrolledUids.contains(uid)) {
                                      selectedLearnersByUid.remove(uid);
                                      removedAuto.add(uid);
                                    }
                                  }
                                  if (removedAuto.isNotEmpty) {
                                    _notify(
                                      "Removed ${removedAuto.length} learner(s) (not enrolled anymore).",
                                    );
                                  }

                                  final courseCode =
                                      (selectedCourse["course_code"] ?? "")
                                          .toString();
                                  final courseTitle =
                                      (selectedCourse["title"] ?? "")
                                          .toString();
                                  final courseDuration =
                                      (selectedCourse["duration"] ?? "")
                                          .toString();
                                  final courseLevel =
                                      (selectedCourse["level"] ?? "")
                                          .toString();
                                  final courseCategory =
                                      (selectedCourse["category"] ?? "")
                                          .toString();

                                  final oldCurrent = (isEdit)
                                      ? (existingClass["instructor_current"]
                                                is Map
                                            ? Map<String, dynamic>.from(
                                                existingClass["instructor_current"],
                                              )
                                            : {
                                                "uid": "",
                                                "name":
                                                    (existingClass["instructor"] ??
                                                            "")
                                                        .toString(),
                                                "serial": "",
                                                "assignedAt":
                                                    (existingClass["updated_at"]),
                                              })
                                      : null;

                                  final newCurrent = <String, dynamic>{
                                    "uid": pickedUid,
                                    "name": pickedName,
                                    "serial":
                                        (selectedInstructorObj?["serial"] ?? "")
                                            .toString(),
                                    "assignedAt": ServerValue.timestamp,
                                  };

                                  final payload = <String, dynamic>{
                                    "class_id": classId,
                                    "status": status,
                                    "is_open": isOpen,

                                    "course_id": courseId,
                                    "course_code": courseCode,
                                    "course_title": courseTitle,
                                    "course_duration": courseDuration,
                                    "course_level": courseLevel,
                                    "category": courseCategory,
                                    "variantKey": selectedVariantKey,
                                    "variantLabel": _variantLabel(
                                      selectedVariantKey,
                                    ),
                                    "studyMode": selectedVariantKey == 'private'
                                        ? selectedStudyMode
                                        : "",
                                    "studyModeLabel":
                                        selectedVariantKey == 'private'
                                        ? _studyModeLabel(selectedStudyMode)
                                        : "",

                                    "instructor": pickedName,
                                    "instructor_current": newCurrent,

                                    "schedule": {
                                      "first_session_date":
                                          requiresFixedSchedule &&
                                              firstSessionDate != null
                                          ? _formatDate(firstSessionDate!)
                                          : "",
                                      "sessions_count": sessionsCount,
                                      "sessions": sessions,
                                    },
                                    "learners": selectedLearnersByUid,
                                    "updated_at": ServerValue.timestamp,
                                    if (!isEdit)
                                      "created_at": ServerValue.timestamp,
                                  };

                                  try {
                                    setSaving(true);

                                    await _classesRef
                                        .child(classId)
                                        .update(payload);

                                    if (isEdit && oldCurrent != null) {
                                      final oldUid = (oldCurrent["uid"] ?? "")
                                          .toString()
                                          .trim();
                                      final newUid = (newCurrent["uid"] ?? "")
                                          .toString()
                                          .trim();

                                      if (oldUid.isNotEmpty &&
                                          oldUid != newUid) {
                                        final histRef = _classesRef
                                            .child(classId)
                                            .child("instructor_history")
                                            .push();
                                        await histRef.set({
                                          ...oldCurrent,
                                          "unassignedAt": ServerValue.timestamp,
                                          "replacedBy": {
                                            "uid": newCurrent["uid"],
                                            "name": newCurrent["name"],
                                            "serial": newCurrent["serial"],
                                          },
                                        });
                                      }
                                    }

                                    await _syncLearnersClassDataStrict(
                                      courseId: courseId,
                                      classPayload: payload,
                                      selectedLearnersByUid:
                                          selectedLearnersByUid,
                                      previousLearnersByUid:
                                          previousLearnersByUid,
                                    );

                                    if (!mounted) return;
                                    Navigator.pop(context);
                                    _notify(
                                      isEdit
                                          ? "Saved: $classId"
                                          : "Class created: $classId",
                                    );
                                  } catch (e) {
                                    _notify(toHumanError(e), error: true);
                                    setSaving(false);
                                  }
                                },
                          child: Text(isEdit ? "Save changes" : "Create class"),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );

    await sheetFuture;
  }

  // -------------------- ✅ Class progress (attendance taught.sessionId vs syllabi sessions) --------------------

  Future<_ClassProg> _loadClassProgress(
    String classId,
    Map<String, dynamic> cls,
  ) async {
    // cache hit
    if (_classProgCache.containsKey(classId)) return _classProgCache[classId]!;

    final courseId = (cls["course_id"] ?? "").toString().trim();
    final rawVariant = (cls["variantKey"] ?? cls["variant"] ?? "").toString();
    final syllabusVariant = syllabusVariantForScheduledAttendance(rawVariant);

    // 1) total sessions from syllabi/<course_id> (same as Teacher screen)
    int totalSessions = await _loadSyllabusSessionCount(
      courseId: courseId,
      syllabusVariant: syllabusVariant,
    );

    // Fallback: if syllabus missing, use schedule.sessions_count
    if (totalSessions <= 0) {
      final sched = (cls["schedule"] is Map)
          ? Map<String, dynamic>.from(cls["schedule"])
          : <String, dynamic>{};
      totalSessions = _asInt(sched["sessions_count"]);
    }

    // 2) covered sessions = unique taught.sessionId from classes/<classId>/attendance/*
    final att = cls["attendance"];
    final Set<String> covered = {};
    int held = 0;

    if (att is Map) {
      final m = Map<String, dynamic>.from(att);
      held = m.length;

      for (final entry in m.entries) {
        final rec = entry.value;
        if (rec is! Map) continue;
        final r = Map<String, dynamic>.from(rec);

        final taughtItems = r["taughtItems"];
        bool countedFromNewFormat = false;

        if (taughtItems is List) {
          countedFromNewFormat = true;
          for (final it in taughtItems) {
            if (it is! Map) continue;
            final item = Map<String, dynamic>.from(it);
            final type = (item["type"] ?? "").toString().trim().toLowerCase();
            if (type != "syllabus") continue;
            final sid = (item["sessionId"] ?? "").toString().trim();
            if (sid.isNotEmpty) covered.add(sid);
          }
        }

        if (!countedFromNewFormat) {
          final taught = r["taught"];
          if (taught is Map) {
            final tm = Map<String, dynamic>.from(taught);
            final sid = (tm["sessionId"] ?? "").toString().trim();
            if (sid.isNotEmpty) covered.add(sid);
          }
        }
      }
    }

    final coveredCount = covered.length;
    final pct = totalSessions <= 0
        ? 0
        : ((coveredCount / totalSessions) * 100).round().clamp(0, 100);

    final prog = _ClassProg(
      percent: pct,
      coveredCount: coveredCount,
      totalSessions: totalSessions,
      sessionsHeld: held,
    );

    _classProgCache[classId] = prog;
    return prog;
  }

  Future<int> _loadSyllabusSessionCount({
    required String courseId,
    required String syllabusVariant,
  }) async {
    if (courseId.isEmpty) return 0;

    final key = '$courseId|$syllabusVariant';
    final cached = _syllabusSessionCountCache[key];
    if (cached != null) return cached;

    int totalSessions = 0;
    var sSnap = await _syllabiRef.child(courseId).child(syllabusVariant).get();
    if ((!sSnap.exists || sSnap.value is! Map) &&
        syllabusVariant == 'private') {
      sSnap = await _syllabiRef.child(courseId).child('inclass').get();
    }

    if (sSnap.exists && sSnap.value is Map) {
      final s = Map<String, dynamic>.from(sSnap.value as Map);
      final modules = s['modules'];
      if (modules is List) {
        for (final m in modules) {
          if (m is! Map) continue;
          final module = Map<String, dynamic>.from(m);
          final units = module['units'];
          if (units is! List) continue;
          for (final u in units) {
            if (u is! Map) continue;
            final unit = Map<String, dynamic>.from(u);
            final lessons = unit['lessons'];
            if (lessons is List) totalSessions += lessons.length;
          }
        }
      } else {
        final units = s['units'];
        if (units is List) {
          for (final u in units) {
            if (u is! Map) continue;
            final unit = Map<String, dynamic>.from(u);
            final sessions = unit['sessions'];
            if (sessions is List) totalSessions += sessions.length;
          }
        }
      }
    }

    _syllabusSessionCountCache[key] = totalSessions;
    return totalSessions;
  }

  Future<Map<int, Map<String, dynamic>>> _loadFlexibleSyllabusSessions(
    String courseId,
  ) async {
    final cid = courseId.trim();
    if (cid.isEmpty) return const <int, Map<String, dynamic>>{};

    final cached = _flexibleSyllabusCache[cid];
    if (cached != null) return cached;

    final out = <int, Map<String, dynamic>>{};
    try {
      final snap = await _syllabiRef.child(cid).child('flexible').get();
      if (!snap.exists || snap.value is! Map) {
        _flexibleSyllabusCache[cid] = out;
        return out;
      }

      final root = Map<dynamic, dynamic>.from(snap.value as Map);
      final units = root['units'];
      int fallbackNo = 1;

      if (units is List) {
        for (final u in units) {
          if (u is! Map) continue;
          final um = Map<dynamic, dynamic>.from(u);
          final sessions = um['sessions'];
          if (sessions is! List) continue;

          for (final s in sessions) {
            if (s is! Map) continue;
            final sm = Map<String, dynamic>.from(s as Map);
            int no = _asInt(sm['sessionNo']);
            if (no <= 0) no = _asInt(sm['sessionNumber']);
            if (no <= 0) no = _asInt(sm['order']);
            if (no <= 0) no = fallbackNo;

            out[no] = {
              'sessionNo': no,
              'sessionTitle': (sm['sessionTitle'] ?? sm['title'] ?? '')
                  .toString()
                  .trim(),
              'title': (sm['title'] ?? '').toString().trim(),
              'objective': (sm['objective'] ?? '').toString().trim(),
              'content': (sm['content'] ?? '').toString().trim(),
              'homework': (sm['homework'] ?? '').toString().trim(),
              'durationMinutes': _asInt(sm['durationMinutes']),
              'source': 'syllabi/flexible',
            };

            fallbackNo += 1;
          }
        }
      }

      if (out.isEmpty) {
        for (final entry in root.entries) {
          final keyNo = int.tryParse(entry.key.toString()) ?? 0;
          final raw = entry.value;
          if (raw is! Map) continue;
          final sm = Map<String, dynamic>.from(raw as Map);
          int no = _asInt(sm['sessionNo']);
          if (no <= 0) no = _asInt(sm['sessionNumber']);
          if (no <= 0) no = _asInt(sm['order']);
          if (no <= 0) no = keyNo;
          if (no <= 0) continue;

          out[no] = {
            'sessionNo': no,
            'sessionTitle': (sm['sessionTitle'] ?? sm['title'] ?? '')
                .toString()
                .trim(),
            'title': (sm['title'] ?? '').toString().trim(),
            'objective': (sm['objective'] ?? '').toString().trim(),
            'content': (sm['content'] ?? '').toString().trim(),
            'homework': (sm['homework'] ?? '').toString().trim(),
            'durationMinutes': _asInt(sm['durationMinutes']),
            'source': 'syllabi/flexible',
          };
        }
      }
    } catch (_) {}

    _flexibleSyllabusCache[cid] = out;
    return out;
  }

  Future<Map<String, dynamic>?> _loadFlexibleSessionInfoByNo(
    String courseId,
    int sessionNo,
  ) async {
    if (courseId.trim().isEmpty || sessionNo <= 0) return null;

    final syllabus = await _loadFlexibleSyllabusSessions(courseId);
    final fromSyllabus = syllabus[sessionNo];
    if (fromSyllabus != null) return fromSyllabus;

    try {
      final snap = await _db
          .child('booking_curriculum/$courseId/sessions/$sessionNo')
          .get();
      if (snap.exists && snap.value is Map) {
        final m = Map<String, dynamic>.from(snap.value as Map);
        return {
          'sessionNo': sessionNo,
          'sessionTitle': (m['sessionTitle'] ?? m['title'] ?? '')
              .toString()
              .trim(),
          'title': (m['title'] ?? '').toString().trim(),
          'objective': (m['objective'] ?? '').toString().trim(),
          'content': (m['content'] ?? '').toString().trim(),
          'homework': (m['homework'] ?? '').toString().trim(),
          'durationMinutes': _asInt(m['durationMinutes']),
          'source': 'booking_curriculum',
        };
      }
    } catch (_) {}

    return null;
  }

  Future<void> _openFlexibleSessionDetailsSheet({
    required String courseId,
    required _FlexAttendanceRow row,
  }) async {
    if (row.sessionNo <= 0) return;

    final info = await _loadFlexibleSessionInfoByNo(courseId, row.sessionNo);
    if (!mounted) return;

    final title = (info?['sessionTitle'] ?? info?['title'] ?? row.lessonTitle)
        .toString()
        .trim();
    final objective = (info?['objective'] ?? '').toString().trim();
    final content = (info?['content'] ?? '').toString().trim();
    final homework = (info?['homework'] ?? '').toString().trim();
    final source = (info?['source'] ?? 'not_found').toString().trim();

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title.isEmpty
                        ? 'Session ${row.sessionNo}'
                        : 'Session ${row.sessionNo} — $title',
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF1A2B48),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Teacher: ${row.teacherName.isEmpty ? '-' : row.teacherName}',
                    style: TextStyle(
                      color: Colors.grey.shade800,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Source: $source',
                    style: TextStyle(
                      color: Colors.grey.shade700,
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                  if (row.taughtTitle.isNotEmpty &&
                      title.isNotEmpty &&
                      row.taughtTitle.toLowerCase() != title.toLowerCase()) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Teacher taught title: ${row.taughtTitle}',
                      style: TextStyle(
                        color: Colors.orange.shade800,
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  _detailsBlock('Objective', objective),
                  const SizedBox(height: 10),
                  _detailsBlock('Content', content),
                  const SizedBox(height: 10),
                  _detailsBlock('Homework', homework),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _detailsBlock(String title, String body) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontWeight: FontWeight.w900,
            color: Color(0xFF1A2B48),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          body.isEmpty ? '-' : body,
          style: TextStyle(
            color: Colors.grey.shade800,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }

  // -------------------- Classes List UI --------------------

  Widget _buildTopFilters() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 900;
        final twoColWidth = (constraints.maxWidth - 10) / 2;

        return Wrap(
          spacing: 10,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: narrow
                  ? constraints.maxWidth
                  : constraints.maxWidth * 0.52,
              child: TextField(
                controller: _searchCtrl,
                decoration: const InputDecoration(
                  isDense: true,
                  prefixIcon: Icon(Icons.search),
                  labelText: "Search (ID / course / instructor / learner)",
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            SizedBox(
              width: narrow ? twoColWidth : 170,
              child: DropdownButtonFormField<String>(
                initialValue: _dayFilter,
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: 'Day',
                  border: OutlineInputBorder(),
                ),
                items: [
                  const DropdownMenuItem(value: "All", child: Text("All days")),
                  ..._weekDays.map(
                    (d) => DropdownMenuItem(value: d, child: Text(d)),
                  ),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  setState(() => _dayFilter = v);
                },
              ),
            ),
            SizedBox(
              width: narrow ? twoColWidth : 170,
              child: DropdownButtonFormField<String>(
                initialValue: _openFilter == null
                    ? 'all'
                    : (_openFilter! ? 'open' : 'closed'),
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: 'Status',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(value: 'all', child: Text('All')),
                  DropdownMenuItem(value: 'open', child: Text('Open only')),
                  DropdownMenuItem(value: 'closed', child: Text('Closed only')),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  setState(() {
                    if (v == 'all') {
                      _openFilter = null;
                    } else if (v == 'open') {
                      _openFilter = true;
                    } else {
                      _openFilter = false;
                    }
                  });
                },
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildClassesList() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildTopFilters(),
        const SizedBox(height: 12),
        Expanded(
          child: FutureBuilder<DataSnapshot>(
            future: _classesFuture,
            builder: (context, snap) {
              if (snap.hasError) {
                return Center(
                  child: Text(
                    'Could not load classes right now.',
                    style: TextStyle(
                      color: Colors.red.shade700,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                );
              }
              if (snap.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }

              final data = snap.data?.value;
              if (data == null || data is! Map) {
                return const Center(child: Text("No classes yet."));
              }

              final map = Map<dynamic, dynamic>.from(data);

              final allClasses = map.values
                  .whereType<dynamic>()
                  .map((e) => Map<String, dynamic>.from(e as Map))
                  .toList();

              final filtered = allClasses
                  .where(_matchesSearch)
                  .where(_matchesDayFilter)
                  .where(_matchesOpenFilter)
                  .toList();

              filtered.sort((a, b) {
                final aa = (a["created_at"] ?? 0) is int
                    ? (a["created_at"] as int)
                    : 0;
                final bb = (b["created_at"] ?? 0) is int
                    ? (b["created_at"] as int)
                    : 0;
                return bb.compareTo(aa);
              });

              // Summary line
              final summary =
                  "Showing ${filtered.length} of ${allClasses.length} classes";

              if (filtered.isEmpty) {
                return Center(
                  child: Text(
                    "No matching classes.\n$summary",
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                );
              }

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          summary,
                          style: TextStyle(
                            color: Colors.grey.shade700,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Refresh classes',
                        onPressed: () {
                          setState(() {
                            _classesFuture = _classesRef.get();
                          });
                        },
                        icon: const Icon(Icons.refresh_rounded),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: ListView.separated(
                      padding: const EdgeInsets.only(bottom: 90),
                      itemCount: filtered.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, i) {
                        final cls = filtered[i];

                        final id = (cls["class_id"] ?? "").toString();
                        final classKey = id.isEmpty ? 'class_$i' : id;
                        final expanded = _expandedClassIds.contains(classKey);
                        final status = (cls["status"] ?? "active").toString();

                        final courseTitle = (cls["course_title"] ?? "")
                            .toString();
                        final variantKey = (cls["variantKey"] ?? "").toString();
                        final studyMode = (cls["studyMode"] ?? "").toString();
                        final classTypeLabel = _classTypeLabel(
                          variantKey: variantKey,
                          studyMode: studyMode,
                        );

                        final instructor = (cls["instructor"] ?? "").toString();

                        final sched = (cls["schedule"] is Map)
                            ? Map<String, dynamic>.from(cls["schedule"])
                            : <String, dynamic>{};
                        final firstDate = (sched["first_session_date"] ?? "")
                            .toString();
                        final learners = _classLearnersList(cls);

                        return Card(
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                            side: BorderSide(
                              color: Colors.grey.withValues(alpha: 0.25),
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        courseTitle.isEmpty
                                            ? (id.isEmpty ? '-' : id)
                                            : courseTitle,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w900,
                                          fontSize: 16,
                                        ),
                                      ),
                                    ),
                                    PopupMenuButton<String>(
                                      tooltip: 'Class actions',
                                      onSelected: (value) {
                                        if (value == 'edit') {
                                          _openClassEditor(existingClass: cls);
                                          return;
                                        }
                                        if (value == 'pause') {
                                          _setClassStatus(id, 'paused');
                                          return;
                                        }
                                        if (value == 'block') {
                                          _setClassStatus(id, 'blocked');
                                          return;
                                        }
                                        if (value == 'activate') {
                                          _setClassStatus(id, 'active');
                                          return;
                                        }
                                        if (value == 'delete') {
                                          _deleteClass(id);
                                        }
                                      },
                                      itemBuilder: (context) => [
                                        const PopupMenuItem(
                                          value: 'edit',
                                          child: Text('Edit'),
                                        ),
                                        const PopupMenuDivider(),
                                        PopupMenuItem(
                                          value: 'activate',
                                          enabled: status != 'active',
                                          child: const Text('Activate'),
                                        ),
                                        PopupMenuItem(
                                          value: 'pause',
                                          enabled: status != 'paused',
                                          child: const Text('Pause'),
                                        ),
                                        PopupMenuItem(
                                          value: 'block',
                                          enabled: status != 'blocked',
                                          child: const Text('Block'),
                                        ),
                                        const PopupMenuDivider(),
                                        const PopupMenuItem(
                                          value: 'delete',
                                          child: Text('Delete'),
                                        ),
                                      ],
                                      icon: const Icon(Icons.more_vert_rounded),
                                    ),
                                    IconButton(
                                      tooltip: expanded
                                          ? 'Collapse learners'
                                          : 'Expand learners',
                                      onPressed: learners.isEmpty
                                          ? null
                                          : () {
                                              setState(() {
                                                if (expanded) {
                                                  _expandedClassIds.remove(
                                                    classKey,
                                                  );
                                                } else {
                                                  _expandedClassIds.add(
                                                    classKey,
                                                  );
                                                }
                                              });
                                            },
                                      icon: Icon(
                                        expanded
                                            ? Icons.keyboard_arrow_up_rounded
                                            : Icons.keyboard_arrow_down_rounded,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                if (classTypeLabel.trim().isNotEmpty) ...[
                                  Text(
                                    'Variant: $classTypeLabel',
                                    style: TextStyle(
                                      color: Colors.grey.shade800,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                ],
                                Text(
                                  instructor.isEmpty
                                      ? "Instructor: -"
                                      : "Instructor: $instructor",
                                  style: TextStyle(
                                    color: Colors.grey.shade700,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),

                                const SizedBox(height: 6),
                                Text(
                                  firstDate.isEmpty
                                      ? _prettySessions(cls)
                                      : 'Start: $firstDate • ${_prettySessions(cls)}',
                                  style: TextStyle(
                                    color: Colors.grey.shade800,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'Learners: ${learners.length}',
                                  style: TextStyle(
                                    color: Colors.grey.shade700,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                if (expanded) ...[
                                  const SizedBox(height: 6),
                                  if (learners.isEmpty)
                                    Text(
                                      'No learners in this class.',
                                      style: TextStyle(
                                        color: Colors.grey.shade600,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    )
                                  else
                                    ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        maxHeight: 220,
                                      ),
                                      child: ListView.separated(
                                        shrinkWrap: true,
                                        itemCount: learners.length,
                                        separatorBuilder: (_, _) =>
                                            const Divider(height: 1),
                                        itemBuilder: (_, idx) {
                                          final l = learners[idx];
                                          final serial = (l['serial'] ?? '')
                                              .trim();
                                          final name = (l['name'] ?? '').trim();
                                          final title = name.isNotEmpty
                                              ? name
                                              : (serial.isNotEmpty
                                                    ? serial
                                                    : l['uid'] ?? '-');
                                          final subtitle = serial.isNotEmpty
                                              ? 'Serial: $serial'
                                              : null;

                                          return ListTile(
                                            dense: true,
                                            contentPadding:
                                                const EdgeInsets.symmetric(
                                                  horizontal: 6,
                                                ),
                                            leading: const Icon(
                                              Icons.person_rounded,
                                            ),
                                            title: Text(
                                              title,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            subtitle: subtitle == null
                                                ? null
                                                : Text(subtitle),
                                            trailing: const Icon(
                                              Icons.open_in_new_rounded,
                                              size: 18,
                                            ),
                                            onTap: () =>
                                                _openLearnerFromClass(l),
                                          );
                                        },
                                      ),
                                    ),
                                ],
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  bool _isNearExpiryMs(int expiresAt, {int days = 7}) {
    if (expiresAt <= 0) return false;
    final now = DateTime.now().millisecondsSinceEpoch;
    final diff = expiresAt - now;
    if (diff < 0) return false;
    return diff <= Duration(days: days).inMilliseconds;
  }

  String _fmtDateOnlyMs(int ms) {
    if (ms <= 0) return 'No deadline';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    return '${d.year}-$mm-$dd';
  }

  int _effectiveFlexReminder({
    required int sessionsPaidTotal,
    required int remindBeforeSession,
  }) {
    final fallback = remindBeforeSession > 0 ? remindBeforeSession : 2;
    return normalizeReminderForSessions(
      sessionsPaidTotal: sessionsPaidTotal,
      remindBeforeSession: fallback,
    );
  }

  String _flexPaymentStatusLabel({
    required int sessionsPaidTotal,
    required int sessionsPresent,
    required int remindBeforeSession,
    required int expiresAt,
  }) {
    if (sessionsPaidTotal <= 0) return 'No session package';
    if (expiresAt > 0 && DateTime.now().millisecondsSinceEpoch >= expiresAt) {
      return 'Expired';
    }
    if (isPaymentDueBySessions(
      sessionsPaidTotal: sessionsPaidTotal,
      sessionsPresent: sessionsPresent,
    )) {
      return 'Due now';
    }
    if (expiresAt > 0 && _isNearExpiryMs(expiresAt, days: 10)) {
      return 'Near expiry';
    }
    if (isPaymentWarningBySessions(
      sessionsPaidTotal: sessionsPaidTotal,
      sessionsPresent: sessionsPresent,
      remindBeforeSession: _effectiveFlexReminder(
        sessionsPaidTotal: sessionsPaidTotal,
        remindBeforeSession: remindBeforeSession,
      ),
    )) {
      return 'Due soon';
    }
    return 'OK';
  }

  Color _flexStatusColor(String status) {
    switch (status) {
      case 'Due now':
      case 'Expired':
        return Colors.red.shade700;
      case 'Due soon':
      case 'Near expiry':
        return Colors.orange.shade700;
      case 'No session package':
        return Colors.blueGrey.shade700;
      default:
        return Colors.green.shade700;
    }
  }

  String _flexSummaryKey(_FlexCourseSummary item) {
    return '${item.uid}|${item.courseKey}|${item.courseId}';
  }

  Future<List<Map<String, dynamic>>> _loadPaymentsForUidCached(
    String uid,
  ) async {
    final cached = _paymentsByUidCache[uid];
    if (cached != null) return cached;

    final list = <Map<String, dynamic>>[];
    try {
      final snap = await _db
          .child('payments')
          .orderByChild('uid')
          .equalTo(uid)
          .get();
      if (snap.exists && snap.value is Map) {
        final raw = Map<dynamic, dynamic>.from(snap.value as Map);
        for (final entry in raw.entries) {
          if (entry.value is! Map) continue;
          final m = Map<String, dynamic>.from(entry.value as Map);
          m['paymentId'] = entry.key.toString();
          list.add(m);
        }
      }
    } catch (_) {}

    if (list.isEmpty) {
      try {
        final allSnap = await _db.child('payments').get();
        if (allSnap.exists && allSnap.value is Map) {
          final raw = Map<dynamic, dynamic>.from(allSnap.value as Map);
          for (final entry in raw.entries) {
            final v = entry.value;
            if (v is! Map) continue;
            final m = Map<String, dynamic>.from(v);
            final payUid = (m['uid'] ?? '').toString().trim();
            if (payUid == uid) {
              m['paymentId'] = entry.key.toString();
              list.add(m);
            }
          }
        }
      } catch (_) {}
    }

    _paymentsByUidCache[uid] = list;
    return list;
  }

  int _latestFlexibleExpiryFromPayments({
    required List<Map<String, dynamic>> payments,
    required String courseKey,
    required String courseId,
    required String courseTitle,
    required String courseCode,
  }) {
    String norm(String s) => s.trim().toLowerCase();
    final wantedKey = norm(courseKey);
    final wantedId = norm(courseId);
    final wantedTitle = norm(courseTitle);
    final wantedCode = norm(courseCode);

    int ymdToMs(String ymd) {
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

    int addMonthsToMs(int baseMs, int months) {
      if (baseMs <= 0 || months <= 0) return 0;
      final d = DateTime.fromMillisecondsSinceEpoch(baseMs);
      return DateTime(d.year, d.month + months, d.day).millisecondsSinceEpoch;
    }

    var latestStamp = 0;
    var latestExpiresAt = 0;
    for (final p in payments) {
      final payVariant = _normalizeVariantKey(
        (p['variantKey'] ?? p['variant'] ?? '').toString(),
      );
      if (payVariant != 'flexible') continue;

      final payCourseKey = (p['courseKey'] ?? '').toString().trim();
      final payCourseId = (p['course_id'] ?? p['courseId'] ?? '')
          .toString()
          .trim();
      final payCourseTitle = (p['course_title'] ?? p['courseTitle'] ?? '')
          .toString()
          .trim();
      final payCourseCode = (p['course_code'] ?? p['courseCode'] ?? '')
          .toString()
          .trim();

      final keyMatch = wantedKey.isNotEmpty && norm(payCourseKey) == wantedKey;
      final idMatch = wantedId.isNotEmpty && norm(payCourseId) == wantedId;
      final titleMatch =
          wantedTitle.isNotEmpty && norm(payCourseTitle) == wantedTitle;
      final codeMatch =
          wantedCode.isNotEmpty && norm(payCourseCode) == wantedCode;

      if (!(keyMatch || idMatch || titleMatch || codeMatch)) continue;

      final paidAt = _asInt(p['paidAt']);
      final startDate = (p['startDate'] ?? '').toString();
      final expiryMonths = _asInt(p['expiryMonths']);

      var expiresAt = _asInt(p['expiresAt']);
      if (expiresAt <= 0 && startDate.trim().isNotEmpty && expiryMonths > 0) {
        final baseMs = ymdToMs(startDate);
        expiresAt = addMonthsToMs(baseMs, expiryMonths);
      }
      if (expiresAt <= 0) continue;

      final stamp = paidAt > 0 ? paidAt : _asInt(p['createdAt']);
      if (stamp >= latestStamp) {
        latestStamp = stamp;
        latestExpiresAt = expiresAt;
      }
    }

    return latestExpiresAt;
  }

  bool _paymentMatchesFlexible({
    required Map<String, dynamic> payment,
    required _FlexCourseSummary item,
  }) {
    final payVariant = _normalizeVariantKey(
      (payment['variantKey'] ?? payment['variant'] ?? '').toString(),
    );
    if (payVariant != 'flexible') return false;

    final payCourseKey = (payment['courseKey'] ?? '').toString().trim();
    final payCourseId = (payment['course_id'] ?? payment['courseId'] ?? '')
        .toString()
        .trim();
    final payCourseTitle =
        (payment['course_title'] ?? payment['courseTitle'] ?? '')
            .toString()
            .trim()
            .toLowerCase();
    final payCourseCode =
        (payment['course_code'] ?? payment['courseCode'] ?? '')
            .toString()
            .trim()
            .toLowerCase();

    return (payCourseKey.isNotEmpty && payCourseKey == item.courseKey) ||
        (payCourseId.isNotEmpty && payCourseId == item.courseId) ||
        (payCourseTitle.isNotEmpty &&
            payCourseTitle == item.courseTitle.toLowerCase()) ||
        (payCourseCode.isNotEmpty &&
            payCourseCode == item.courseCode.toLowerCase());
  }

  Future<_FlexCourseDetails> _loadFlexCourseDetails(
    _FlexCourseSummary item,
  ) async {
    final syllabusBySession = await _loadFlexibleSyllabusSessions(
      item.courseId,
    );
    final syllabusTitleBySession = <int, String>{};
    for (final e in syllabusBySession.entries) {
      final title = (e.value['sessionTitle'] ?? e.value['title'] ?? '')
          .toString();
      if (title.trim().isNotEmpty) {
        syllabusTitleBySession[e.key] = title.trim();
      }
    }

    final reviewBySessionNo = <int, int>{};
    try {
      final reviewSnap = await _db
          .child(
            'booking_progress/${item.uid}/${item.courseId}/session_reviews',
          )
          .get();
      if (reviewSnap.exists && reviewSnap.value is Map) {
        final reviews = Map<dynamic, dynamic>.from(reviewSnap.value as Map);
        for (final entry in reviews.entries) {
          if (entry.value is! Map) continue;
          final rm = Map<String, dynamic>.from(entry.value as Map);
          final sessionNo = _asInt(rm['sessionNo']);
          if (sessionNo <= 0) continue;
          final rating = _asInt(rm['rating']);
          if (rating >= 1 && rating <= 5) {
            reviewBySessionNo[sessionNo] = rating;
          }
        }
      }
    } catch (_) {}

    final presentRows = <_FlexAttendanceRow>[];
    try {
      final progressSnap = await _db
          .child(
            'booking_progress/${item.uid}/${item.courseId}/online_attendance',
          )
          .get();
      if (progressSnap.exists && progressSnap.value is Map) {
        final att = Map<dynamic, dynamic>.from(progressSnap.value as Map);
        att.forEach((key, value) {
          if (value is! Map) return;
          final m = Map<String, dynamic>.from(value);
          if (m['present'] != true) return;

          final tsRaw = m['startAt'] ?? m['updatedAt'] ?? m['createdAt'];
          int ts = 0;
          if (tsRaw is int) {
            ts = tsRaw;
          } else if (tsRaw is num) {
            ts = tsRaw.toInt();
          } else {
            ts = int.tryParse(tsRaw?.toString() ?? '') ?? 0;
          }

          final sessionNo = _asInt(m['sessionNo']);
          String taughtTitle = '';
          final taughtItems = m['taughtItems'];
          if (taughtItems is List) {
            for (final itemRaw in taughtItems) {
              if (itemRaw is! Map) continue;
              final tm = Map<String, dynamic>.from(itemRaw);
              final taughtNo = _asInt(tm['sessionNumber']);
              if (sessionNo > 0 && taughtNo > 0 && taughtNo != sessionNo) {
                continue;
              }
              final title = (tm['title'] ?? '').toString().trim();
              if (title.isNotEmpty) {
                taughtTitle = title;
                break;
              }
            }
          }

          presentRows.add(
            _FlexAttendanceRow(
              bookingKey: key.toString(),
              sessionNo: sessionNo,
              dayKey: (m['dayKey'] ?? '').toString().trim(),
              time: (m['time'] ?? '').toString().trim(),
              startAt: ts,
              teacherName:
                  (m['teacherName'] ?? m['teacherNameFromBooking'] ?? 'Teacher')
                      .toString()
                      .trim(),
              lessonTitle: syllabusTitleBySession[sessionNo] ?? taughtTitle,
              taughtTitle: taughtTitle,
              reviewRating: reviewBySessionNo[sessionNo] ?? 0,
            ),
          );
        });
      }
    } catch (_) {}

    presentRows.sort((a, b) => b.sortTs.compareTo(a.sortTs));

    final paymentsForUser = await _loadPaymentsForUidCached(item.uid);
    final matchedPayments =
        paymentsForUser
            .where((p) => _paymentMatchesFlexible(payment: p, item: item))
            .toList()
          ..sort((a, b) {
            final ta = _asInt(a['paidAt']) > 0
                ? _asInt(a['paidAt'])
                : _asInt(a['createdAt']);
            final tb = _asInt(b['paidAt']) > 0
                ? _asInt(b['paidAt'])
                : _asInt(b['createdAt']);
            return ta.compareTo(tb);
          });

    final attendanceAsc = [...presentRows]
      ..sort((a, b) => a.sortTs.compareTo(b.sortTs));
    int ptr = 0;
    final paymentBlocks = <_FlexPaymentBlock>[];
    for (final p in matchedPayments) {
      final sessionsPaid = _asInt(p['sessionsPaid']);
      final amount = _asInt(p['amount']);
      final paidAt = _asInt(p['paidAt']) > 0
          ? _asInt(p['paidAt'])
          : _asInt(p['createdAt']);
      final expiresAtPay = _asInt(p['expiresAt']);
      final expiryMonthsPay = _asInt(p['expiryMonths']);

      final allocated = <_FlexAttendanceRow>[];
      var quota = sessionsPaid > 0 ? sessionsPaid : 0;
      while (ptr < attendanceAsc.length && quota > 0) {
        allocated.add(attendanceAsc[ptr]);
        ptr += 1;
        quota -= 1;
      }

      paymentBlocks.add(
        _FlexPaymentBlock(
          paymentId: (p['paymentId'] ?? '').toString(),
          paidAt: paidAt,
          amount: amount,
          sessionsPaid: sessionsPaid,
          expiresAt: expiresAtPay,
          expiryMonths: expiryMonthsPay,
          rows: allocated,
        ),
      );
    }

    if (ptr < attendanceAsc.length) {
      final unallocated = attendanceAsc.sublist(ptr);
      if (paymentBlocks.isNotEmpty) {
        final last = paymentBlocks.removeLast();
        paymentBlocks.add(
          _FlexPaymentBlock(
            paymentId: last.paymentId,
            paidAt: last.paidAt,
            amount: last.amount,
            sessionsPaid: last.sessionsPaid,
            expiresAt: last.expiresAt,
            expiryMonths: last.expiryMonths,
            rows: [...last.rows, ...unallocated],
          ),
        );
      } else {
        paymentBlocks.add(
          _FlexPaymentBlock(
            paymentId: '',
            paidAt: 0,
            amount: 0,
            sessionsPaid: 0,
            expiresAt: item.expiresAt,
            expiryMonths: 0,
            rows: unallocated,
          ),
        );
      }
    }

    return _FlexCourseDetails(rows: presentRows, paymentBlocks: paymentBlocks);
  }

  Future<_FlexCourseDetails> _flexDetailsFor(_FlexCourseSummary item) {
    final key = _flexSummaryKey(item);
    return _flexDetailsFutureByKey.putIfAbsent(
      key,
      () => _loadFlexCourseDetails(item),
    );
  }

  Future<List<_FlexCourseSummary>> _loadFlexibleAttendanceSummaries() async {
    final usersSnap = await _usersRef.get();
    if (!usersSnap.exists || usersSnap.value is! Map) return const [];

    final courseTitleById = <String, String>{};
    for (final c in _courses) {
      final cid = (c['id'] ?? '').toString().trim();
      if (cid.isEmpty) continue;
      courseTitleById[cid] = (c['title'] ?? '').toString().trim();
    }

    final allUsers = Map<dynamic, dynamic>.from(usersSnap.value as Map);
    final out = <_FlexCourseSummary>[];

    for (final userEntry in allUsers.entries) {
      final uid = userEntry.key.toString();
      final raw = userEntry.value;
      if (raw is! Map) continue;

      final user = Map<String, dynamic>.from(raw);
      if (!_isLearnerRole(user['role'])) continue;

      final first = (user['first_name'] ?? '').toString().trim();
      final last = (user['last_name'] ?? '').toString().trim();
      final fullName = '$first $last'.trim().isEmpty
          ? 'Learner'
          : '$first $last'.trim();
      final courses = (user['courses'] is Map)
          ? Map<dynamic, dynamic>.from(user['courses'])
          : <dynamic, dynamic>{};

      for (final cEntry in courses.entries) {
        final courseKey = cEntry.key.toString();
        final cRaw = cEntry.value;
        if (cRaw is! Map) continue;

        final cm = Map<String, dynamic>.from(cRaw);
        final variantKey = _normalizeVariantKey(
          (cm['variantKey'] ?? cm['variant'] ?? '').toString(),
        );
        if (variantKey != 'flexible') continue;

        final courseId = (cm['id'] ?? cm['courseId'] ?? cm['course_id'] ?? '')
            .toString()
            .trim();
        if (courseId.isEmpty) continue;

        final courseTitleRaw = (cm['title'] ?? '').toString().trim();
        final courseCodeRaw = (cm['course_code'] ?? '').toString().trim();
        final mappedTitle = (courseTitleById[courseId] ?? '').trim();
        final courseTitle = courseTitleRaw.isNotEmpty
            ? courseTitleRaw
            : (mappedTitle.isNotEmpty ? mappedTitle : 'Unknown course');

        final syllabusBySession = await _loadFlexibleSyllabusSessions(courseId);
        int syllabusSessionsTotal = await _loadSyllabusSessionCount(
          courseId: courseId,
          syllabusVariant: 'flexible',
        );
        if (syllabusSessionsTotal <= 0) {
          syllabusSessionsTotal = syllabusBySession.length;
        }

        var consumed = 0;
        var latestTs = 0;
        final coveredNos = <int>{};
        try {
          final progressSnap = await _db
              .child('booking_progress/$uid/$courseId/online_attendance')
              .get();
          if (progressSnap.exists && progressSnap.value is Map) {
            final att = Map<dynamic, dynamic>.from(progressSnap.value as Map);
            for (final value in att.values) {
              if (value is! Map) continue;
              final m = Map<String, dynamic>.from(value);
              if (m['present'] != true) continue;
              consumed += 1;
              final sessionNo = _asInt(m['sessionNo']);
              if (sessionNo > 0) coveredNos.add(sessionNo);
              final ts = _asInt(m['startAt']) > 0
                  ? _asInt(m['startAt'])
                  : (_asInt(m['updatedAt']) > 0
                        ? _asInt(m['updatedAt'])
                        : _asInt(m['createdAt']));
              if (ts > latestTs) latestTs = ts;
            }
          }
        } catch (_) {}

        final summaryMap = (cm['payment_summary'] is Map)
            ? Map<String, dynamic>.from(cm['payment_summary'])
            : <String, dynamic>{};
        final sessionsPaidTotal = _asInt(summaryMap['sessionsPaidTotal']);
        final remindBeforeSession = _asInt(summaryMap['remindBeforeSession']);

        final accessMap = (cm['flexible_access'] is Map)
            ? Map<String, dynamic>.from(cm['flexible_access'])
            : <String, dynamic>{};
        int expiresAt = _asInt(accessMap['expiresAt']);
        if (expiresAt <= 0) {
          final sumMap = (cm['payment_summary'] is Map)
              ? Map<String, dynamic>.from(cm['payment_summary'])
              : <String, dynamic>{};
          expiresAt = _asInt(sumMap['expiresAt']);
        }
        if (expiresAt <= 0) {
          final payments = await _loadPaymentsForUidCached(uid);
          expiresAt = _latestFlexibleExpiryFromPayments(
            payments: payments,
            courseKey: courseKey,
            courseId: courseId,
            courseTitle: courseTitle,
            courseCode: courseCodeRaw,
          );
        }

        final coveredSessionNumbers = coveredNos.length;

        final statusLabel = _flexPaymentStatusLabel(
          sessionsPaidTotal: sessionsPaidTotal,
          sessionsPresent: consumed,
          remindBeforeSession: remindBeforeSession,
          expiresAt: expiresAt,
        );

        out.add(
          _FlexCourseSummary(
            uid: uid,
            learnerName: fullName,
            learnerSerial: '',
            assignedCourses: const <String>[],
            courseKey: courseKey,
            courseId: courseId,
            courseTitle: courseTitle,
            courseCode: courseCodeRaw,
            sessionsPaidTotal: sessionsPaidTotal,
            consumed: consumed,
            coveredSessionNumbers: coveredSessionNumbers,
            syllabusSessionsTotal: syllabusSessionsTotal,
            expiresAt: expiresAt,
            statusLabel: statusLabel,
            rows: const <_FlexAttendanceRow>[],
            paymentBlocks: const <_FlexPaymentBlock>[],
            latestTs: latestTs,
          ),
        );
      }
    }

    out.sort((a, b) {
      final ta = a.latestTs;
      final tb = b.latestTs;
      if (ta != tb) return tb.compareTo(ta);
      return a.learnerName.compareTo(b.learnerName);
    });

    return out;
  }

  Future<Map<String, _RecordedSessionMeta>> _loadRecordedSessionMeta(
    String courseId,
  ) async {
    final cid = courseId.trim();
    if (cid.isEmpty) return const <String, _RecordedSessionMeta>{};

    final cached = _recordedSessionMetaCache[cid];
    if (cached != null) return cached;

    final out = <String, _RecordedSessionMeta>{};
    try {
      final snap = await _syllabiRef.child(cid).child('recorded').get();
      if (snap.exists && snap.value is Map) {
        final root = Map<dynamic, dynamic>.from(snap.value as Map);

        void addSession(dynamic raw) {
          if (raw is! Map) return;
          final m = Map<String, dynamic>.from(raw);
          final sessionId = (m['id'] ?? '').toString().trim();
          if (sessionId.isEmpty) return;
          final hasVideo = (m['videoUrl'] ?? '').toString().trim().isNotEmpty;
          final hasMaterials = (m['materialsUrl'] ?? '')
              .toString()
              .trim()
              .isNotEmpty;
          out[sessionId] = _RecordedSessionMeta(
            hasVideo: hasVideo,
            hasMaterials: hasMaterials,
          );
        }

        final modulesRaw = root['modules'];
        if (modulesRaw is List) {
          for (final module in modulesRaw) {
            if (module is! Map) continue;
            final moduleMap = Map<dynamic, dynamic>.from(module);
            final unitsRaw = moduleMap['units'];
            if (unitsRaw is! List) continue;
            for (final unit in unitsRaw) {
              if (unit is! Map) continue;
              final unitMap = Map<dynamic, dynamic>.from(unit);
              final lessonsRaw = unitMap['lessons'];
              if (lessonsRaw is! List) continue;
              for (final lesson in lessonsRaw) {
                addSession(lesson);
              }
            }
          }
        } else {
          final unitsRaw = root['units'];
          if (unitsRaw is List) {
            for (final unit in unitsRaw) {
              if (unit is! Map) continue;
              final unitMap = Map<dynamic, dynamic>.from(unit);
              final sessionsRaw = unitMap['sessions'];
              if (sessionsRaw is! List) continue;
              for (final session in sessionsRaw) {
                addSession(session);
              }
            }
          }
        }
      }
    } catch (_) {}

    _recordedSessionMetaCache[cid] = out;
    return out;
  }

  Future<List<_RecordedCourseSummary>> _loadRecordedProgressSummaries() async {
    final usersSnap = await _usersRef.get();
    if (!usersSnap.exists || usersSnap.value is! Map) return const [];

    final courseTitleById = <String, String>{};
    for (final c in _courses) {
      final cid = (c['id'] ?? '').toString().trim();
      if (cid.isEmpty) continue;
      final title = (c['title'] ?? '').toString().trim();
      if (title.isNotEmpty) {
        courseTitleById[cid] = title;
      }
    }

    final usersMap = Map<dynamic, dynamic>.from(usersSnap.value as Map);
    final out = <_RecordedCourseSummary>[];

    for (final userEntry in usersMap.entries) {
      final uid = userEntry.key.toString().trim();
      if (uid.isEmpty) continue;
      if (userEntry.value is! Map) continue;

      final user = Map<String, dynamic>.from(userEntry.value as Map);
      if (!_isLearnerRole(user['role'])) continue;

      final first = (user['first_name'] ?? '').toString().trim();
      final last = (user['last_name'] ?? '').toString().trim();
      final fullName = '$first $last'.trim();
      final email = (user['email'] ?? '').toString().trim();
      final learnerName = fullName.isNotEmpty
          ? fullName
          : (email.isNotEmpty ? email : 'Learner');

      final coursesRaw = user['courses'];
      if (coursesRaw is! Map) continue;
      final courses = Map<dynamic, dynamic>.from(coursesRaw);

      for (final cEntry in courses.entries) {
        final courseKey = cEntry.key.toString().trim();
        if (courseKey.isEmpty || cEntry.value is! Map) continue;

        final courseNode = Map<String, dynamic>.from(cEntry.value as Map);
        final variantKey = _normalizeVariantKey(
          (courseNode['variantKey'] ?? courseNode['variant'] ?? '').toString(),
        );
        if (variantKey != 'recorded') continue;

        final courseId =
            (courseNode['id'] ??
                    courseNode['courseId'] ??
                    courseNode['course_id'] ??
                    '')
                .toString()
                .trim();
        if (courseId.isEmpty) continue;

        final titleRaw = (courseNode['title'] ?? '').toString().trim();
        final courseTitle = titleRaw.isNotEmpty
            ? titleRaw
            : (courseTitleById[courseId] ?? 'Unknown course');
        final summaryMap = (courseNode['payment_summary'] is Map)
            ? Map<String, dynamic>.from(courseNode['payment_summary'])
            : <String, dynamic>{};
        final accessMap = (courseNode['recorded_access'] is Map)
            ? Map<String, dynamic>.from(courseNode['recorded_access'])
            : <String, dynamic>{};

        final expiresAt = _asInt(accessMap['expiresAt']) > 0
            ? _asInt(accessMap['expiresAt'])
            : _asInt(summaryMap['expiresAt']);
        final durationMonths = _asInt(accessMap['durationMonths']) > 0
            ? _asInt(accessMap['durationMonths'])
            : _asInt(summaryMap['durationMonths']);
        final lastPaymentAt = _asInt(summaryMap['lastPaymentAt']);

        final progressRaw = courseNode['recorded_progress'];
        final recordedProgress = progressRaw is Map
            ? progressRaw.map((k, v) => MapEntry(k.toString(), v))
            : <String, dynamic>{};

        final sessionMeta = await _loadRecordedSessionMeta(courseId);

        int totalSessions = sessionMeta.length;
        int completedSessions = 0;

        if (sessionMeta.isNotEmpty) {
          for (final sessionEntry in sessionMeta.entries) {
            final progressAny = recordedProgress[sessionEntry.key];
            if (progressAny is! Map) continue;
            final progress = progressAny.map((k, v) => MapEntry('$k', v));

            final videoDone = _asBool(progress['videoCompleted']);
            final materialsDone = _asBool(progress['materialsCompleted']);

            final hasVideo = sessionEntry.value.hasVideo;
            final hasMaterials = sessionEntry.value.hasMaterials;

            bool done = false;
            if (hasVideo && hasMaterials) {
              done = videoDone || materialsDone;
            } else if (hasVideo) {
              done = videoDone;
            } else if (hasMaterials) {
              done = materialsDone;
            }
            if (done) completedSessions += 1;
          }
        } else if (recordedProgress.isNotEmpty) {
          totalSessions = recordedProgress.length;
          for (final value in recordedProgress.values) {
            if (value is! Map) continue;
            final progress = value.map((k, v) => MapEntry('$k', v));
            if (_asBool(progress['videoCompleted']) ||
                _asBool(progress['materialsCompleted'])) {
              completedSessions += 1;
            }
          }
        }

        final progressPct = totalSessions > 0
            ? ((completedSessions / totalSessions) * 100).round().clamp(0, 100)
            : 0;

        out.add(
          _RecordedCourseSummary(
            uid: uid,
            learnerName: learnerName,
            courseKey: courseKey,
            courseId: courseId,
            courseTitle: courseTitle,
            completedSessions: completedSessions,
            totalSessions: totalSessions,
            progressPct: progressPct,
            expiresAt: expiresAt,
            durationMonths: durationMonths,
            lastPaymentAt: lastPaymentAt,
          ),
        );
      }
    }

    out.sort((a, b) {
      final n = a.learnerName.toLowerCase().compareTo(
        b.learnerName.toLowerCase(),
      );
      if (n != 0) return n;
      return a.courseTitle.toLowerCase().compareTo(b.courseTitle.toLowerCase());
    });
    return out;
  }

  _FlexCourseSummary _summaryWithDetails({
    required _FlexCourseSummary item,
    required _FlexCourseDetails details,
  }) {
    return _FlexCourseSummary(
      uid: item.uid,
      learnerName: item.learnerName,
      learnerSerial: item.learnerSerial,
      assignedCourses: item.assignedCourses,
      courseKey: item.courseKey,
      courseId: item.courseId,
      courseTitle: item.courseTitle,
      courseCode: item.courseCode,
      sessionsPaidTotal: item.sessionsPaidTotal,
      consumed: item.consumed,
      coveredSessionNumbers: item.coveredSessionNumbers,
      syllabusSessionsTotal: item.syllabusSessionsTotal,
      expiresAt: item.expiresAt,
      statusLabel: item.statusLabel,
      rows: details.rows,
      paymentBlocks: details.paymentBlocks,
      latestTs: item.latestTs,
    );
  }

  double _recordedPaymentProgress(_RecordedCourseSummary item) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final end = item.expiresAt;
    if (end <= 0) return 0;

    var start = item.lastPaymentAt;
    if (start <= 0 && item.durationMonths > 0) {
      final e = DateTime.fromMillisecondsSinceEpoch(end);
      start = DateTime(
        e.year,
        e.month - item.durationMonths,
        e.day,
      ).millisecondsSinceEpoch;
    }

    if (start <= 0) return now >= end ? 1 : 0;
    final span = end - start;
    if (span <= 0) return now >= end ? 1 : 0;

    final progress = (now - start) / span;
    return progress.clamp(0.0, 1.0);
  }

  Widget _buildFlexibleAttendanceTab() {
    return FutureBuilder<List<_FlexCourseSummary>>(
      future: _loadFlexibleAttendanceSummaries(),
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(
            child: Text(
              'Could not load flexible attendance.',
              style: TextStyle(
                color: Colors.red.shade700,
                fontWeight: FontWeight.w800,
              ),
            ),
          );
        }
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final all = snap.data ?? const <_FlexCourseSummary>[];
        final shown = all.where((item) {
          final statusOk =
              _flexStatusFilter == 'all' ||
              item.statusLabel.toLowerCase() == _flexStatusFilter;
          if (!statusOk) return false;

          if (_flexSearch.isEmpty) return true;
          final q = _flexSearch;
          return item.learnerName.toLowerCase().contains(q) ||
              item.courseTitle.toLowerCase().contains(q);
        }).toList();

        final consumedCount = shown.fold<int>(
          0,
          (sum, item) => sum + item.consumed,
        );

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _flexSearchCtrl,
              decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search),
                labelText: 'Search learner / course',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final item in const <String>[
                    'all',
                    'due now',
                    'due soon',
                    'near expiry',
                    'expired',
                    'no session package',
                  ]) ...[
                    ChoiceChip(
                      label: Text(
                        item == 'all'
                            ? 'All'
                            : item[0].toUpperCase() + item.substring(1),
                      ),
                      selected: _flexStatusFilter == item,
                      onSelected: (_) {
                        setState(() => _flexStatusFilter = item);
                      },
                    ),
                    const SizedBox(width: 8),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Showing ${shown.length} learner-course items • $consumedCount consumed sessions',
                    style: TextStyle(
                      color: Colors.grey.shade700,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Refresh flexible',
                  onPressed: () {
                    setState(() {
                      _paymentsByUidCache.clear();
                      _flexDetailsFutureByKey.clear();
                    });
                  },
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Expanded(
              child: shown.isEmpty
                  ? const Center(child: Text('No flexible attendance found.'))
                  : ListView.separated(
                      itemCount: shown.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, i) {
                        final item = shown[i];
                        final progressValue = item.syllabusSessionsTotal > 0
                            ? (item.coveredSessionNumbers /
                                      item.syllabusSessionsTotal)
                                  .clamp(0.0, 1.0)
                            : 0.0;
                        final paymentValue = item.sessionsPaidTotal > 0
                            ? (item.consumed / item.sessionsPaidTotal).clamp(
                                0.0,
                                1.0,
                              )
                            : 0.0;
                        final isExpired =
                            item.expiresAt > 0 &&
                            DateTime.now().millisecondsSinceEpoch >=
                                item.expiresAt;
                        final nearExpiry =
                            !isExpired &&
                            _isNearExpiryMs(item.expiresAt, days: 7);
                        final nearFinish = progressValue >= 0.85;
                        final key = _flexSummaryKey(item);
                        final expanded = _expandedFlexKeys.contains(key);

                        return Card(
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                            side: BorderSide(
                              color: Colors.grey.withValues(alpha: 0.25),
                            ),
                          ),
                          child: ExpansionTile(
                            key: ValueKey(key),
                            tilePadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 4,
                            ),
                            childrenPadding: const EdgeInsets.fromLTRB(
                              12,
                              0,
                              12,
                              12,
                            ),
                            initiallyExpanded: expanded,
                            onExpansionChanged: (value) {
                              setState(() {
                                if (value) {
                                  _expandedFlexKeys.add(key);
                                } else {
                                  _expandedFlexKeys.remove(key);
                                }
                              });
                            },
                            title: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  item.learnerName,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w900,
                                    color: Color(0xFF1A2B48),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  'Course: ${item.courseTitle}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: Colors.grey.shade800,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 4,
                                      ),
                                      decoration: BoxDecoration(
                                        color: _flexStatusColor(
                                          item.statusLabel,
                                        ).withValues(alpha: 0.14),
                                        borderRadius: BorderRadius.circular(
                                          999,
                                        ),
                                        border: Border.all(
                                          color: _flexStatusColor(
                                            item.statusLabel,
                                          ).withValues(alpha: 0.35),
                                        ),
                                      ),
                                      child: Text(
                                        item.statusLabel,
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: _flexStatusColor(
                                            item.statusLabel,
                                          ),
                                          fontWeight: FontWeight.w900,
                                        ),
                                      ),
                                    ),
                                    if (nearExpiry)
                                      _smallCue(
                                        'Expiry soon',
                                        Colors.orange.shade700,
                                      ),
                                    if (isExpired)
                                      _smallCue('Expired', Colors.red.shade700),
                                    if (nearFinish)
                                      _smallCue(
                                        'Near finish',
                                        const Color(0xFFD97706),
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  item.syllabusSessionsTotal > 0
                                      ? 'Course progress: ${item.coveredSessionNumbers} / ${item.syllabusSessionsTotal}'
                                      : 'Course progress: -',
                                  style: TextStyle(
                                    color: Colors.grey.shade800,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 12,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(999),
                                  child: LinearProgressIndicator(
                                    value: progressValue,
                                    minHeight: 9,
                                    backgroundColor: const Color(0xFFE5E7EB),
                                    valueColor:
                                        const AlwaysStoppedAnimation<Color>(
                                          Color(0xFF2563EB),
                                        ),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  item.sessionsPaidTotal > 0
                                      ? 'Payment progress: ${item.consumed} / ${item.sessionsPaidTotal}'
                                      : 'Payment progress: no package total',
                                  style: TextStyle(
                                    color: Colors.grey.shade800,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 12,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(999),
                                  child: LinearProgressIndicator(
                                    value: paymentValue,
                                    minHeight: 9,
                                    backgroundColor: const Color(0xFFE5E7EB),
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                      _flexStatusColor(item.statusLabel),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            children: [
                              if (expanded)
                                FutureBuilder<_FlexCourseDetails>(
                                  future: _flexDetailsFor(item),
                                  builder: (context, detailSnap) {
                                    if (!detailSnap.hasData) {
                                      return const Padding(
                                        padding: EdgeInsets.symmetric(
                                          vertical: 8,
                                        ),
                                        child: LinearProgressIndicator(
                                          minHeight: 2,
                                        ),
                                      );
                                    }

                                    final detailed = _summaryWithDetails(
                                      item: item,
                                      details: detailSnap.data!,
                                    );

                                    return Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        const SizedBox(height: 6),
                                        Text(
                                          'Deadline: ${_fmtDateOnlyMs(item.expiresAt)}',
                                          style: TextStyle(
                                            color: Colors.grey.shade800,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                        const SizedBox(height: 10),
                                        _FlexLearnerDetailsTabs(
                                          item: detailed,
                                          fmtDateOnlyMs: _fmtDateOnlyMs,
                                          onOpenSessionDetails: (row) {
                                            return _openFlexibleSessionDetailsSheet(
                                              courseId: item.courseId,
                                              row: row,
                                            );
                                          },
                                        ),
                                      ],
                                    );
                                  },
                                ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _smallCue(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w900,
          color: color,
        ),
      ),
    );
  }

  Widget _buildRecordedProgressTab() {
    return FutureBuilder<List<_RecordedCourseSummary>>(
      future: _loadRecordedProgressSummaries(),
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(
            child: Text(
              'Could not load recorded progress.',
              style: TextStyle(
                color: Colors.red.shade700,
                fontWeight: FontWeight.w800,
              ),
            ),
          );
        }
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final rows = snap.data ?? const <_RecordedCourseSummary>[];
        final totalCompleted = rows.fold<int>(
          0,
          (sum, item) => sum + item.completedSessions,
        );
        final totalSessions = rows.fold<int>(
          0,
          (sum, item) => sum + item.totalSessions,
        );

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Showing ${rows.length} recorded learner-course items • $totalCompleted / $totalSessions sessions completed',
                    style: TextStyle(
                      color: Colors.grey.shade700,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Refresh recorded progress',
                  onPressed: () => setState(() {}),
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Expanded(
              child: rows.isEmpty
                  ? const Center(child: Text('No recorded progress found.'))
                  : ListView.separated(
                      itemCount: rows.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, i) {
                        final item = rows[i];
                        final progressValue = item.totalSessions > 0
                            ? (item.completedSessions / item.totalSessions)
                                  .clamp(0.0, 1.0)
                            : 0.0;
                        final paymentValue = _recordedPaymentProgress(item);
                        final expired =
                            item.expiresAt > 0 &&
                            DateTime.now().millisecondsSinceEpoch >=
                                item.expiresAt;
                        final nearExpiry =
                            !expired &&
                            _isNearExpiryMs(item.expiresAt, days: 7);
                        final nearFinish = progressValue >= 0.85;
                        final almostFinish = progressValue >= 0.95;
                        final courseColor = almostFinish
                            ? const Color(0xFF16A34A)
                            : (nearFinish
                                  ? const Color(0xFFD97706)
                                  : const Color(0xFF2563EB));
                        final paymentColor = expired
                            ? Colors.red.shade700
                            : (nearExpiry
                                  ? Colors.orange.shade700
                                  : const Color(0xFF0EA5E9));

                        return Card(
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                            side: BorderSide(
                              color: Colors.grey.withValues(alpha: 0.25),
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  item.learnerName,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w900,
                                    color: Color(0xFF1A2B48),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  'Course: ${item.courseTitle}',
                                  style: TextStyle(
                                    color: Colors.grey.shade800,
                                    fontWeight: FontWeight.w700,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Recorded progress: ${item.completedSessions} / ${item.totalSessions}',
                                  style: TextStyle(
                                    color: Colors.grey.shade800,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  item.expiresAt > 0
                                      ? 'Access expires: ${_fmtDateOnlyMs(item.expiresAt)}'
                                      : 'Access expires: -',
                                  style: TextStyle(
                                    color: Colors.grey.shade800,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Progress: ${item.progressPct}%',
                                  style: TextStyle(
                                    color: Colors.grey.shade800,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: [
                                    if (nearExpiry)
                                      _smallCue(
                                        'Expiry soon',
                                        Colors.orange.shade700,
                                      ),
                                    if (expired)
                                      _smallCue('Expired', Colors.red.shade700),
                                    if (nearFinish && !almostFinish)
                                      _smallCue(
                                        'Near finish',
                                        const Color(0xFFD97706),
                                      ),
                                    if (almostFinish)
                                      _smallCue(
                                        'Almost finished',
                                        const Color(0xFF16A34A),
                                      ),
                                  ],
                                ),
                                if (nearExpiry || expired || nearFinish)
                                  const SizedBox(height: 8),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(999),
                                  child: LinearProgressIndicator(
                                    value: progressValue,
                                    minHeight: 10,
                                    backgroundColor: const Color(0xFFE5E7EB),
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                      courseColor,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'Payment duration progress',
                                  style: TextStyle(
                                    color: Colors.grey.shade800,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(999),
                                  child: LinearProgressIndicator(
                                    value: paymentValue,
                                    minHeight: 10,
                                    backgroundColor: const Color(0xFFE5E7EB),
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                      paymentColor,
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
        );
      },
    );
  }

  // -------------------- Build --------------------

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Classes'),
          actions: [const SizedBox.shrink()],
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Classes'),
              Tab(text: 'Flexible'),
              Tab(text: 'Recorded'),
            ],
          ),
        ),
        body: adminWebBodyFrame(
          context: context,
          maxWidth: 1560,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: TabBarView(
              children: [
                _buildClassesList(),
                _buildFlexibleAttendanceTab(),
                _buildRecordedProgressTab(),
              ],
            ),
          ),
        ),
        floatingActionButton: FloatingActionButton(
          onPressed: () => _openClassEditor(existingClass: null),
          child: const Icon(Icons.add),
        ),
      ),
    );
  }
}

// -------------------- Helpers --------------------

class _FlexLearnerDetailsTabs extends StatefulWidget {
  const _FlexLearnerDetailsTabs({
    required this.item,
    required this.fmtDateOnlyMs,
    required this.onOpenSessionDetails,
  });

  final _FlexCourseSummary item;
  final String Function(int) fmtDateOnlyMs;
  final Future<void> Function(_FlexAttendanceRow row) onOpenSessionDetails;

  @override
  State<_FlexLearnerDetailsTabs> createState() =>
      _FlexLearnerDetailsTabsState();
}

class _FlexLearnerDetailsTabsState extends State<_FlexLearnerDetailsTabs> {
  int _tabIndex = 0;

  Color _reviewBg(int rating) {
    switch (rating) {
      case 5:
        return const Color(0xFFE8F5E9);
      case 4:
        return const Color(0xFFF1F8E9);
      case 3:
        return const Color(0xFFFFF8E1);
      case 2:
        return const Color(0xFFFFF3E0);
      case 1:
        return const Color(0xFFFFEBEE);
      default:
        return const Color(0xFFF8FAFB);
    }
  }

  Color _reviewBorder(int rating) {
    switch (rating) {
      case 5:
        return const Color(0xFF66BB6A);
      case 4:
        return const Color(0xFF9CCC65);
      case 3:
        return const Color(0xFFFBC02D);
      case 2:
        return const Color(0xFFFFA726);
      case 1:
        return const Color(0xFFEF5350);
      default:
        return Colors.grey.withValues(alpha: 0.25);
    }
  }

  Widget _reviewStars(int rating) {
    if (rating < 1 || rating > 5) {
      return Text(
        'Review: Not rated',
        style: TextStyle(
          color: Colors.grey.shade700,
          fontWeight: FontWeight.w700,
          fontSize: 12,
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Review: ',
          style: TextStyle(
            color: Colors.grey.shade700,
            fontWeight: FontWeight.w700,
            fontSize: 12,
          ),
        ),
        ...List.generate(5, (i) {
          final on = i < rating;
          return Icon(
            on ? Icons.star_rounded : Icons.star_border_rounded,
            size: 15,
            color: const Color(0xFFF59E0B),
          );
        }),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final paidAmount = item.paymentBlocks.fold<int>(
      0,
      (sum, p) => sum + p.amount,
    );
    final sessionsLeft = (item.sessionsPaidTotal - item.consumed).clamp(
      0,
      9999,
    );

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFB),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ChoiceChip(
                label: const Text('Payment'),
                selected: _tabIndex == 0,
                onSelected: (_) => setState(() => _tabIndex = 0),
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                label: const Text('Attendance'),
                selected: _tabIndex == 1,
                onSelected: (_) => setState(() => _tabIndex = 1),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (_tabIndex == 0) ...[
            Text(
              'Amount $paidAmount   Session paid ${item.sessionsPaidTotal}   Left $sessionsLeft',
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                color: Color(0xFF1A2B48),
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 8),
            if (item.paymentBlocks.isEmpty)
              Text(
                'No payment rows found for this course yet.',
                style: TextStyle(
                  color: Colors.grey.shade700,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              )
            else
              ...item.paymentBlocks.asMap().entries.map((e) {
                final idx = e.key;
                final block = e.value;
                final paidDate = block.paidAt > 0
                    ? widget.fmtDateOnlyMs(block.paidAt)
                    : '-';
                final blockDeadline = block.expiresAt > 0
                    ? widget.fmtDateOnlyMs(block.expiresAt)
                    : widget.fmtDateOnlyMs(item.expiresAt);
                final blockLeft = (block.sessionsPaid - block.rows.length)
                    .clamp(0, 9999);

                return Container(
                  margin: const EdgeInsets.only(top: 8),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: Colors.grey.withValues(alpha: 0.25),
                    ),
                  ),
                  child: Text(
                    'Payment ${idx + 1} | Paid: $paidDate | Amount: ${block.amount} | Studied: ${block.rows.length}${block.sessionsPaid > 0 ? ' / ${block.sessionsPaid}' : ''} | Left: ${block.sessionsPaid > 0 ? blockLeft : '-'} | Deadline: $blockDeadline',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF1A2B48),
                      fontSize: 12,
                    ),
                  ),
                );
              }),
          ] else ...[
            if (item.rows.isEmpty)
              Text(
                'No attendance rows found.',
                style: TextStyle(
                  color: Colors.grey.shade700,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              )
            else
              ...item.rows.asMap().entries.map((entry) {
                final i = entry.key + 1;
                final row = entry.value;
                final lesson = row.lessonTitle.isEmpty ? '-' : row.lessonTitle;
                final teacher = row.teacherName.isEmpty
                    ? 'Teacher'
                    : row.teacherName;
                final reviewLabel =
                    row.reviewRating >= 1 && row.reviewRating <= 5
                    ? '${row.reviewRating}/5'
                    : '-';
                final rating = row.reviewRating;

                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: _reviewBg(rating),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: _reviewBorder(rating)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              '$i) S${row.sessionNo <= 0 ? '-' : row.sessionNo} • $lesson',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Color(0xFF1A2B48),
                                fontWeight: FontWeight.w900,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          _reviewStars(row.reviewRating),
                          const SizedBox(width: 4),
                          IconButton(
                            tooltip: 'Session details',
                            onPressed: row.sessionNo <= 0
                                ? null
                                : () => widget.onOpenSessionDetails(row),
                            icon: const Icon(
                              Icons.error_outline_rounded,
                              size: 18,
                            ),
                            visualDensity: VisualDensity.compact,
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Teacher: $teacher',
                        style: TextStyle(
                          color: Colors.grey.shade800,
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        row.whenLabel,
                        style: TextStyle(
                          color: Colors.grey.shade700,
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Review: $reviewLabel',
                        style: TextStyle(
                          color: Colors.grey.shade800,
                          fontWeight: FontWeight.w800,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                );
              }),
          ],
        ],
      ),
    );
  }
}

class _ScheduleRow {
  _ScheduleRow({required this.day});
  String day;
  String? startTime;
  final TextEditingController durationCtrl = TextEditingController(text: "90");
}

class _ClassProg {
  final int percent;
  final int coveredCount;
  final int totalSessions;
  final int sessionsHeld;

  const _ClassProg({
    required this.percent,
    required this.coveredCount,
    required this.totalSessions,
    required this.sessionsHeld,
  });

  factory _ClassProg.zero() => const _ClassProg(
    percent: 0,
    coveredCount: 0,
    totalSessions: 0,
    sessionsHeld: 0,
  );
}

class _FlexAttendanceRow {
  final String bookingKey;
  final int sessionNo;
  final String dayKey;
  final String time;
  final int startAt;
  final String teacherName;
  final String lessonTitle;
  final String taughtTitle;
  final int reviewRating;

  const _FlexAttendanceRow({
    required this.bookingKey,
    required this.sessionNo,
    required this.dayKey,
    required this.time,
    required this.startAt,
    required this.teacherName,
    required this.lessonTitle,
    required this.taughtTitle,
    required this.reviewRating,
  });

  int get sortTs {
    if (startAt > 0) return startAt;
    final parsed = DateTime.tryParse('$dayKey $time');
    if (parsed == null) return 0;
    return parsed.millisecondsSinceEpoch;
  }

  String get whenLabel {
    if (dayKey.isNotEmpty && time.isNotEmpty) return '$dayKey $time';
    if (dayKey.isNotEmpty) return dayKey;
    if (startAt > 0) {
      final d = DateTime.fromMillisecondsSinceEpoch(startAt);
      final mm = d.month.toString().padLeft(2, '0');
      final dd = d.day.toString().padLeft(2, '0');
      final hh = d.hour.toString().padLeft(2, '0');
      final mi = d.minute.toString().padLeft(2, '0');
      return '${d.year}-$mm-$dd $hh:$mi';
    }
    return '-';
  }
}

class _FlexCourseSummary {
  final String uid;
  final String learnerName;
  final String learnerSerial;
  final List<String> assignedCourses;
  final String courseKey;
  final String courseId;
  final String courseTitle;
  final String courseCode;
  final int sessionsPaidTotal;
  final int consumed;
  final int coveredSessionNumbers;
  final int syllabusSessionsTotal;
  final int expiresAt;
  final String statusLabel;
  final List<_FlexAttendanceRow> rows;
  final List<_FlexPaymentBlock> paymentBlocks;
  final int latestTs;

  const _FlexCourseSummary({
    required this.uid,
    required this.learnerName,
    required this.learnerSerial,
    required this.assignedCourses,
    required this.courseKey,
    required this.courseId,
    required this.courseTitle,
    required this.courseCode,
    required this.sessionsPaidTotal,
    required this.consumed,
    required this.coveredSessionNumbers,
    required this.syllabusSessionsTotal,
    required this.expiresAt,
    required this.statusLabel,
    required this.rows,
    required this.paymentBlocks,
    required this.latestTs,
  });
}

class _FlexCourseDetails {
  final List<_FlexAttendanceRow> rows;
  final List<_FlexPaymentBlock> paymentBlocks;

  const _FlexCourseDetails({required this.rows, required this.paymentBlocks});
}

class _FlexPaymentBlock {
  final String paymentId;
  final int paidAt;
  final int amount;
  final int sessionsPaid;
  final int expiresAt;
  final int expiryMonths;
  final List<_FlexAttendanceRow> rows;

  const _FlexPaymentBlock({
    required this.paymentId,
    required this.paidAt,
    required this.amount,
    required this.sessionsPaid,
    required this.expiresAt,
    required this.expiryMonths,
    required this.rows,
  });
}

class _RecordedSessionMeta {
  final bool hasVideo;
  final bool hasMaterials;

  const _RecordedSessionMeta({
    required this.hasVideo,
    required this.hasMaterials,
  });
}

class _RecordedCourseSummary {
  final String uid;
  final String learnerName;
  final String courseKey;
  final String courseId;
  final String courseTitle;
  final int completedSessions;
  final int totalSessions;
  final int progressPct;
  final int expiresAt;
  final int durationMonths;
  final int lastPaymentAt;

  const _RecordedCourseSummary({
    required this.uid,
    required this.learnerName,
    required this.courseKey,
    required this.courseId,
    required this.courseTitle,
    required this.completedSessions,
    required this.totalSessions,
    required this.progressPct,
    required this.expiresAt,
    required this.durationMonths,
    required this.lastPaymentAt,
  });
}
