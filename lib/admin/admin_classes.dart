import 'dart:math';
import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:intl/intl.dart';

class AdminClassesScreen extends StatefulWidget {
  const AdminClassesScreen({super.key});

  @override
  State<AdminClassesScreen> createState() => _AdminClassesScreenState();
}

class _AdminClassesScreenState extends State<AdminClassesScreen> {
  // ====== DB NODES ======
  static const String coursesNode = "courses";
  static const String classesNode = "classes";
  static const String usersNode = "users"; // learners live here

  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  late final DatabaseReference _coursesRef = _db.child(coursesNode);
  late final DatabaseReference _classesRef = _db.child(classesNode);
  late final DatabaseReference _usersRef = _db.child(usersNode);

  // ===== Courses cache =====
  bool _loadingCourses = true;
  List<Map<String, dynamic>> _courses = [];

  // ===== Learners cache (ALL learners) =====
  bool _loadingLearners = true;
  List<Map<String, dynamic>> _allLearners = []; // {uid, serial, name, coursesMap}

  // ===== Search =====
  final TextEditingController _searchCtrl = TextEditingController();
  String _searchQuery = "";

  @override
  void initState() {
    super.initState();
    _loadCourses();
    _loadAllLearners();

    _searchCtrl.addListener(() {
      setState(() => _searchQuery = _searchCtrl.text.trim().toLowerCase());
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  // -------------------- Utilities --------------------

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  String _formatDate(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

  bool _isLearnerRole(dynamic role) {
    final r = (role ?? "").toString().trim().toLowerCase();
    return r == "learner" || r == "learners" || r == "learner(s)";
  }

  String _levelShort(String levelRaw) {
    final t = levelRaw.trim();
    if (t.isEmpty) return "CLS";
    return t.split(RegExp(r'\s+')).first;
  }

  /// Short Class ID: exactly 5 chars (human-friendly)
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

  // -------------------- Load courses --------------------

  Future<void> _loadCourses() async {
    setState(() => _loadingCourses = true);

    final snap = await _coursesRef.get();
    final List<Map<String, dynamic>> list = [];

    if (snap.exists && snap.value is Map) {
      final map = Map<dynamic, dynamic>.from(snap.value as Map);

      for (final entry in map.entries) {
        final id = entry.key.toString();
        final data = Map<String, dynamic>.from(entry.value as Map);

        final levelRaw = (data["level"] ?? "").toString();

        list.add({
          "id": id,
          "title": data["title"] ?? "",
          "course_code": data["course_code"] ?? "",
          "duration": data["duration"] ?? "",
          "category": data["category"] ?? "",
          "level": _levelShort(levelRaw),
          "instructors": (data["instructors"] is List)
              ? List<String>.from(data["instructors"])
              : <String>[],
        });
      }

      list.sort((a, b) =>
          (a["course_code"] as String).compareTo(b["course_code"] as String));
    }

    setState(() {
      _courses = list;
      _loadingCourses = false;
    });
  }

  // -------------------- Load ALL learners --------------------

  Future<void> _loadAllLearners() async {
    setState(() => _loadingLearners = true);

    final snap = await _usersRef.get();
    final List<Map<String, dynamic>> list = [];

    if (snap.exists && snap.value is Map) {
      final all = Map<dynamic, dynamic>.from(snap.value as Map);

      for (final entry in all.entries) {
        final uid = entry.key.toString();
        final data = Map<String, dynamic>.from(entry.value as Map);

        if (!_isLearnerRole(data["role"])) continue;

        final serial = (data["serial"] ?? "").toString().trim();
        final first = (data["first_name"] ?? "").toString().trim();
        final last = (data["last_name"] ?? "").toString().trim();
        final name = "$first $last".trim();

        final coursesMap = (data["courses"] is Map)
            ? Map<String, dynamic>.from((data["courses"] as Map).map(
              (k, v) => MapEntry(
            k.toString(),
            v is Map ? Map<String, dynamic>.from(v) : v,
          ),
        ))
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

    setState(() {
      _allLearners = list;
      _loadingLearners = false;
    });
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
      _toast("Updated: $classId → $status");
    } catch (e) {
      _toast("Failed: $e");
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
            ? Map<String, dynamic>.from((cls["learners"] as Map)
            .map((k, v) => MapEntry(k.toString(), v)))
            : <String, dynamic>{};

        await _syncLearnersClassDataStrict(
          courseId: courseId,
          classPayload: {"class_id": classId, "course_id": courseId},
          selectedLearnersByUid: const <String, dynamic>{},
          previousLearnersByUid: prevLearners,
        );
      }

      await _classesRef.child(classId).remove();
      _toast("Deleted: $classId");
    } catch (e) {
      _toast("Failed: $e");
    }
  }

  // -------------------- Search + UI helpers --------------------

  bool _matchesSearch(Map<String, dynamic> cls) {
    if (_searchQuery.isEmpty) return true;
    final id = (cls["class_id"] ?? "").toString().toLowerCase();
    final title = (cls["course_title"] ?? "").toString().toLowerCase();
    final code = (cls["course_code"] ?? "").toString().toLowerCase();
    final inst = (cls["instructor"] ?? "").toString().toLowerCase();
    return id.contains(_searchQuery) ||
        title.contains(_searchQuery) ||
        code.contains(_searchQuery) ||
        inst.contains(_searchQuery);
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

  String _prettySessions(Map<String, dynamic> cls) {
    final sched =
    (cls["schedule"] is Map) ? Map<String, dynamic>.from(cls["schedule"]) : {};
    final sessions =
    (sched["sessions"] is List) ? List<dynamic>.from(sched["sessions"]) : [];
    if (sessions.isEmpty) return "No schedule";

    final parts = sessions.map((s) {
      final m = (s is Map) ? Map<String, dynamic>.from(s) : {};
      final day = (m["day"] ?? "").toString();
      final time = (m["start_time"] ?? "").toString();
      final dur = (m["duration_min"] ?? "").toString();
      return "$day $time (${dur}m)";
    }).toList();

    return parts.join(" • ");
  }

  // -------------------- Learner Picker (STRICT ENROLLMENT) --------------------

  Future<void> _openLearnersPickerStrict({
    required String selectedCourseId,
    required Map<String, dynamic> selectedLearnersByUid,
    required StateSetter setModalState,
  }) async {
    if (_loadingLearners) {
      _toast("Learners are still loading...");
      return;
    }

    final enrolledUids = _uidsWhoHaveCourse(selectedCourseId);

    final TextEditingController searchCtrl = TextEditingController();
    String q = "";

    await showDialog(
      context: context,
      useRootNavigator: true,
      builder: (_) {
        return StatefulBuilder(builder: (context, setDState) {
          final filtered = _allLearners.where((l) {
            if (q.isEmpty) return true;
            final serial = (l["serial"] ?? "").toString().toLowerCase();
            final name = (l["name"] ?? "").toString().toLowerCase();
            return serial.contains(q) || name.contains(q);
          }).toList();

          return AlertDialog(
            title: const Text("Pick learners"),
            content: SizedBox(
              width: double.maxFinite,
              height: 460,
              child: Column(
                children: [
                  TextField(
                    controller: searchCtrl,
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: "Search by name or ID (serial)",
                    ),
                    onChanged: (v) => setDState(() => q = v.trim().toLowerCase()),
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
                        final isSelected = selectedLearnersByUid.containsKey(uid);

                        return CheckboxListTile(
                          value: isSelected,
                          onChanged: (val) {
                            if (!isEnrolled) {
                              _toast("This learner is not enrolled in this course. Assign course first.");
                              return;
                            }

                            setDState(() {
                              if (val == true) {
                                selectedLearnersByUid[uid] = {"serial": serial, "name": name};
                              } else {
                                selectedLearnersByUid.remove(uid);
                              }
                            });
                            setModalState(() {});
                          },
                          title: Row(
                            children: [
                              Expanded(
                                child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                              ),
                              Container(
                                margin: const EdgeInsets.only(left: 8),
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(999),
                                  color: isEnrolled
                                      ? Colors.blue.withOpacity(0.12)
                                      : Colors.grey.withOpacity(0.10),
                                  border: Border.all(
                                    color: isEnrolled
                                        ? Colors.blue.withOpacity(0.35)
                                        : Colors.grey.withOpacity(0.35),
                                  ),
                                ),
                                child: Text(
                                  isEnrolled ? "Enrolled" : "Not enrolled",
                                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800),
                                ),
                              ),
                            ],
                          ),
                          subtitle: Text("ID: $serial"),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text("Done")),
            ],
          );
        });
      },
    );

    searchCtrl.dispose();
  }

  // -------------------- Full Create/Edit Bottom Sheet --------------------

  Future<void> _openClassEditor({Map<String, dynamic>? existingClass}) async {
    if (_loadingCourses) return _toast("Courses are still loading...");
    if (_courses.isEmpty) return _toast("No courses found.");

    final bool isEdit = existingClass != null;

    // Generate & show class ID immediately
    final String classId = isEdit
        ? (existingClass["class_id"] ?? "").toString()
        : await _generateUniqueClassId();

    // Initial course (LOCKED in edit mode)
    Map<String, dynamic> selectedCourse = _courses.first;
    if (isEdit) {
      final courseId = (existingClass["course_id"] ?? "").toString();
      final found = _courses.where((c) => c["id"] == courseId).toList();
      if (found.isNotEmpty) selectedCourse = found.first;
    }

    // Instructor
    final instructors = (selectedCourse["instructors"] as List<String>);
    String? selectedInstructor =
    instructors.isNotEmpty ? instructors.first : null;
    if (isEdit) {
      final exInst = (existingClass["instructor"] ?? "").toString();
      if (exInst.isNotEmpty) selectedInstructor = exInst;
    }

    // Status
    final String status =
    isEdit ? (existingClass["status"] ?? "active").toString() : "active";

    // Schedule
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
        final m = (item is Map) ? Map<String, dynamic>.from(item) : {};
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

    // Learners
    Map<String, dynamic> previousLearnersByUid = {};
    Map<String, dynamic> selectedLearnersByUid = {};

    if (isEdit && existingClass["learners"] is Map) {
      previousLearnersByUid = Map<String, dynamic>.from(
        (existingClass["learners"] as Map).map((k, v) => MapEntry(k.toString(), v)),
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

    await showModalBottomSheet(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) {
        return StatefulBuilder(builder: (context, setModalState) {
          final learnersCount = selectedLearnersByUid.length;
          final courseId = selectedCourse["id"].toString();

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
                            isEdit ? "Edit Class" : "Add Class",
                            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(999),
                            color: Colors.black.withOpacity(0.06),
                          ),
                          child: Text("ID: $classId", style: const TextStyle(fontWeight: FontWeight.w900)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // COURSE (LOCKED IN EDIT MODE)
                    if (isEdit)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.grey.withOpacity(0.35)),
                          color: Colors.grey.withOpacity(0.06),
                        ),
                        child: Text(
                          "Course: ${selectedCourse["course_code"]} — ${selectedCourse["title"]}",
                          style: const TextStyle(fontWeight: FontWeight.w800),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      )
                    else
                      DropdownButtonFormField<Map<String, dynamic>>(
                        isExpanded: true,
                        value: selectedCourse,
                        decoration: const InputDecoration(labelText: "Course", border: OutlineInputBorder()),
                        selectedItemBuilder: (context) {
                          return _courses.map((c) {
                            final label = "${c["course_code"]} — ${c["title"]}";
                            return Align(
                              alignment: Alignment.centerLeft,
                              child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
                            );
                          }).toList();
                        },
                        items: _courses.map((c) {
                          final label = "${c["course_code"]} — ${c["title"]}";
                          return DropdownMenuItem<Map<String, dynamic>>(
                            value: c,
                            child: SizedBox(
                              width: double.infinity,
                              child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
                            ),
                          );
                        }).toList(),
                        onChanged: (val) {
                          if (val == null) return;
                          setModalState(() {
                            selectedCourse = val;
                            final ins = (val["instructors"] as List<String>);
                            selectedInstructor = ins.isNotEmpty ? ins.first : null;
                          });
                        },
                      ),

                    const SizedBox(height: 12),

                    DropdownButtonFormField<String>(
                      isExpanded: true,
                      value: selectedInstructor,
                      decoration: const InputDecoration(labelText: "Instructor", border: OutlineInputBorder()),
                      items: ((selectedCourse["instructors"] as List<String>))
                          .map((name) => DropdownMenuItem(
                        value: name,
                        child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                      ))
                          .toList(),
                      onChanged: (val) => setModalState(() => selectedInstructor = val),
                    ),

                    const SizedBox(height: 12),

                    TextField(
                      controller: sessionsCountCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: "Number of sessions", border: OutlineInputBorder()),
                    ),

                    const SizedBox(height: 12),

                    OutlinedButton.icon(
                      onPressed: () => pickDate(setModalState),
                      icon: const Icon(Icons.date_range),
                      label: Text(firstSessionDate == null
                          ? "Pick first session date"
                          : "First session: ${_formatDate(firstSessionDate!)}"),
                    ),

                    const SizedBox(height: 12),

                    OutlinedButton.icon(
                      onPressed: () => _openLearnersPickerStrict(
                        selectedCourseId: courseId,
                        selectedLearnersByUid: selectedLearnersByUid,
                        setModalState: setModalState,
                      ),
                      icon: const Icon(Icons.people_alt_rounded),
                      label: Text(
                        _loadingLearners
                            ? "Loading learners..."
                            : learnersCount == 0
                            ? "Pick learners"
                            : "Learners selected: $learnersCount",
                      ),
                    ),

                    const SizedBox(height: 16),
                    const Text("Weekly schedule (day / start time / duration)",
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 8),

                    ...scheduleRows.map((row) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Row(
                          children: [
                            SizedBox(width: 62, child: Text(row.day, style: const TextStyle(fontWeight: FontWeight.w700))),
                            const SizedBox(width: 8),
                            Expanded(
                              child: OutlinedButton(
                                onPressed: () => pickTime(setModalState, row),
                                child: Text(row.startTime == null ? "Start time" : row.startTime!),
                              ),
                            ),
                            const SizedBox(width: 8),
                            SizedBox(
                              width: 120,
                              child: TextField(
                                controller: row.durationCtrl,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(labelText: "Minutes", border: OutlineInputBorder()),
                              ),
                            ),
                            IconButton(
                              tooltip: "Remove",
                              onPressed: () {
                                if (scheduleRows.length <= 1) return;
                                setModalState(() => scheduleRows.remove(row));
                              },
                              icon: const Icon(Icons.close),
                            ),
                          ],
                        ),
                      );
                    }),

                    OutlinedButton.icon(
                      onPressed: () => setModalState(() => scheduleRows.add(_ScheduleRow(day: "Mon"))),
                      icon: const Icon(Icons.add),
                      label: const Text("Add another day"),
                    ),

                    const SizedBox(height: 18),

                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () async {
                          if (selectedInstructor == null || selectedInstructor!.trim().isEmpty) {
                            return _toast("Pick an instructor.");
                          }

                          final sessionsCount = int.tryParse(sessionsCountCtrl.text.trim());
                          if (sessionsCount == null || sessionsCount <= 0) return _toast("Sessions count invalid.");
                          if (firstSessionDate == null) return _toast("Pick the first session date.");

                          final sessions = <Map<String, dynamic>>[];
                          for (final row in scheduleRows) {
                            if (row.startTime == null) return _toast("Pick start time for ${row.day}.");
                            final dur = int.tryParse(row.durationCtrl.text.trim());
                            if (dur == null || dur <= 0) return _toast("Duration invalid for ${row.day}.");
                            sessions.add({"day": row.day, "start_time": row.startTime, "duration_min": dur});
                          }

                          final enrolledUids = _uidsWhoHaveCourse(courseId);
                          final notEnrolledSelected = selectedLearnersByUid.keys
                              .where((uid) => !enrolledUids.contains(uid))
                              .toList();

                          if (notEnrolledSelected.isNotEmpty) {
                            _toast("Some selected learners are not enrolled in this course. Assign course first.");
                            return;
                          }

                          final courseCode = (selectedCourse["course_code"] ?? "").toString();
                          final courseTitle = (selectedCourse["title"] ?? "").toString();
                          final courseDuration = (selectedCourse["duration"] ?? "").toString();
                          final courseLevel = (selectedCourse["level"] ?? "").toString();
                          final courseCategory = (selectedCourse["category"] ?? "").toString();

                          final payload = <String, dynamic>{
                            "class_id": classId,
                            "status": status,
                            "course_id": courseId,
                            "course_code": courseCode,
                            "course_title": courseTitle,
                            "course_duration": courseDuration,
                            "course_level": courseLevel,
                            "category": courseCategory,
                            "instructor": selectedInstructor,
                            "schedule": {
                              "first_session_date": _formatDate(firstSessionDate!),
                              "sessions_count": sessionsCount,
                              "sessions": sessions,
                            },
                            "learners": selectedLearnersByUid,
                            "updated_at": ServerValue.timestamp,
                            if (!isEdit) "created_at": ServerValue.timestamp,
                          };

                          try {
                            await _classesRef.child(classId).update(payload);

                            await _syncLearnersClassDataStrict(
                              courseId: courseId,
                              classPayload: payload,
                              selectedLearnersByUid: selectedLearnersByUid,
                              previousLearnersByUid: previousLearnersByUid,
                            );

                            if (!mounted) return;
                            Navigator.pop(context);
                            _toast(isEdit ? "Saved: $classId" : "Class created: $classId");
                          } catch (e) {
                            _toast("Failed: $e");
                          } finally {
                            for (final r in scheduleRows) {
                              r.durationCtrl.dispose();
                            }
                            sessionsCountCtrl.dispose();
                          }
                        },
                        child: Text(isEdit ? "Save Changes" : "Create Class"),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        });
      },
    );
  }

  // -------------------- Classes List UI --------------------

  Widget _buildClassesList() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _searchCtrl,
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search),
            labelText: "Search (ID / course / instructor)",
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),

        StreamBuilder<DatabaseEvent>(
          stream: _classesRef.onValue,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              );
            }

            final data = snap.data?.snapshot.value;
            if (data == null || data is! Map) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: Text("No classes yet.")),
              );
            }

            final map = Map<dynamic, dynamic>.from(data);
            final classes = map.values
                .whereType<dynamic>()
                .map((e) => Map<String, dynamic>.from(e as Map))
                .where(_matchesSearch)
                .toList();

            classes.sort((a, b) {
              final aa = (a["created_at"] ?? 0) is int ? (a["created_at"] as int) : 0;
              final bb = (b["created_at"] ?? 0) is int ? (b["created_at"] as int) : 0;
              return bb.compareTo(aa);
            });

            if (classes.isEmpty) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: Text("No matching classes.")),
              );
            }

            return ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: classes.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, i) {
                final cls = classes[i];

                final id = (cls["class_id"] ?? "").toString();
                final status = (cls["status"] ?? "active").toString();
                final course = (cls["course_title"] ?? "").toString();
                final code = (cls["course_code"] ?? "").toString();
                final instructor = (cls["instructor"] ?? "").toString();

                final sched = (cls["schedule"] is Map) ? Map<String, dynamic>.from(cls["schedule"]) : {};
                final firstDate = (sched["first_session_date"] ?? "").toString();
                final sessionsCount = (sched["sessions_count"] ?? "").toString();

                final learners = (cls["learners"] is Map) ? Map<dynamic, dynamic>.from(cls["learners"]) : null;
                final learnersCount = learners?.length ?? 0;

                return Card(
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                    side: BorderSide(color: Colors.grey.withOpacity(0.25)),
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
                                id,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                              decoration: BoxDecoration(
                                color: _statusColor(status).withOpacity(0.12),
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(color: _statusColor(status).withOpacity(0.35)),
                              ),
                              child: Text(
                                status.toUpperCase(),
                                style: TextStyle(
                                  color: _statusColor(status),
                                  fontWeight: FontWeight.w900,
                                  fontSize: 11,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          "$code — $course",
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          "Instructor: $instructor",
                          style: TextStyle(color: Colors.grey.shade700, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          "Start: ${firstDate.isEmpty ? '-' : firstDate}  •  Sessions: ${sessionsCount.isEmpty ? '-' : sessionsCount}  •  Learners: $learnersCount",
                          style: TextStyle(color: Colors.grey.shade700, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _prettySessions(cls),
                          style: TextStyle(color: Colors.grey.shade800, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            OutlinedButton.icon(
                              onPressed: () => _openClassEditor(existingClass: cls),
                              icon: const Icon(Icons.edit, size: 18),
                              label: const Text("Edit"),
                            ),
                            OutlinedButton.icon(
                              onPressed: status == "paused" ? null : () => _setClassStatus(id, "paused"),
                              icon: const Icon(Icons.pause_circle, size: 18),
                              label: const Text("Pause"),
                            ),
                            OutlinedButton.icon(
                              onPressed: status == "blocked" ? null : () => _setClassStatus(id, "blocked"),
                              icon: const Icon(Icons.block, size: 18),
                              label: const Text("Block"),
                            ),
                            OutlinedButton.icon(
                              onPressed: status == "active" ? null : () => _setClassStatus(id, "active"),
                              icon: const Icon(Icons.play_circle, size: 18),
                              label: const Text("Activate"),
                            ),
                            TextButton.icon(
                              onPressed: () => _deleteClass(id),
                              icon: const Icon(Icons.delete, color: Colors.red, size: 18),
                              label: const Text("Delete", style: TextStyle(color: Colors.red)),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Classes')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: _buildClassesList(),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openClassEditor(existingClass: null),
        child: const Icon(Icons.add),
      ),
    );
  }
}

// -------------------- Helpers --------------------

class _ScheduleRow {
  _ScheduleRow({required this.day});
  final String day;
  String? startTime; // "HH:mm"
  final TextEditingController durationCtrl = TextEditingController(text: "90");
}
