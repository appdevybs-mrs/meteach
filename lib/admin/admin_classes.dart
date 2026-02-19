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
  
  import 'dart:math';
  import 'package:flutter/material.dart';
  import 'package:firebase_database/firebase_database.dart';
  import 'package:intl/intl.dart';
  import 'package:flutter/cupertino.dart';

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
  
    final DatabaseReference _db = FirebaseDatabase.instance.ref();
    late final DatabaseReference _coursesRef = _db.child(coursesNode);
    late final DatabaseReference _classesRef = _db.child(classesNode);
    late final DatabaseReference _usersRef = _db.child(usersNode);
  
    // ✅ Always-visible notifications (even above modals)
    final GlobalKey<ScaffoldMessengerState> _messengerKey = GlobalKey<ScaffoldMessengerState>();
  
    // ===== Courses cache =====
    bool _loadingCourses = true;
    List<Map<String, dynamic>> _courses = [];
    late final Future<void> _bootFuture;
  
    // ===== Learners cache (ALL learners) =====
    bool _loadingLearners = true;
    List<Map<String, dynamic>> _allLearners = []; // {uid, serial, name, coursesMap}
  
    // ===== Teachers cache (ALL teachers) =====
    bool _loadingTeachers = true;
    Map<String, Map<String, String>> _teachersByUid = {}; // uid -> {uid,name,serial}
    Map<String, String> _teacherUidByName = {}; // normalizedFullName -> uid
  
    List<Map<String, String>> get _teachers {
      final list = _teachersByUid.values.toList();
      list.sort((a, b) => (a["name"] ?? "").compareTo(b["name"] ?? ""));
      return list;
    }
  
    // ===== Search =====
    final TextEditingController _searchCtrl = TextEditingController();
    String _searchQuery = "";
  
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
      _loadAllLearners();
  
      _searchCtrl.addListener(() {
        if (!mounted) return;
        setState(() => _searchQuery = _searchCtrl.text.trim().toLowerCase());
      });
    }
  
    @override
    void dispose() {
      _searchCtrl.dispose();
      super.dispose();
    }
  
    // -------------------- Notifications --------------------
  
    void _notify(String msg, {bool error = false}) {
      if (!mounted) return;
  
      final ms = _messengerKey.currentState;
      if (ms == null) return;
  
      ms.clearMaterialBanners();
      ms.showMaterialBanner(
        MaterialBanner(
          backgroundColor: error ? Colors.red.withOpacity(0.08) : Colors.black.withOpacity(0.06),
          content: Text(
            msg,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: error ? Colors.red.shade800 : Colors.black87,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => ms.clearMaterialBanners(),
              child: const Text("OK"),
            ),
          ],
        ),
      );
  
      Future.delayed(const Duration(seconds: 3), () {
        if (!mounted) return;
        _messengerKey.currentState?.clearMaterialBanners();
      });
    }
  
    // -------------------- Utilities --------------------
  
    String _formatDate(DateTime d) => DateFormat('yyyy-MM-dd').format(d);
    String _norm(String s) => s.trim().toLowerCase();
  
    bool _isLearnerRole(dynamic role) {
      final r = (role ?? "").toString().trim().toLowerCase();
      return r == "learner" || r == "learners" || r == "learner(s)";
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
  
            instructorsList.sort((a, b) => (a["name"] ?? "").compareTo(b["name"] ?? ""));
  
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
  
          list.sort((a, b) => (a["course_code"] as String).compareTo(b["course_code"] as String));
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
          final m = (e.value is Map) ? Map<String, dynamic>.from(e.value) : <String, dynamic>{};
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
      final removedUids =
      previousLearnersByUid.keys.where((uid) => !selectedLearnersByUid.containsKey(uid)).toList();
  
      for (final uid in removedUids) {
        final userSnap = await _usersRef.child(uid).get();
        if (!userSnap.exists || userSnap.value is! Map) continue;
  
        final userData = Map<String, dynamic>.from(userSnap.value as Map);
        final courses = (userData["courses"] is Map)
            ? Map<dynamic, dynamic>.from(userData["courses"])
            : <dynamic, dynamic>{};
  
        String? courseKey;
        for (final entry in courses.entries) {
          final m = (entry.value is Map) ? Map<String, dynamic>.from(entry.value) : <String, dynamic>{};
          if ((m["id"] ?? "").toString() == courseId) {
            courseKey = entry.key.toString();
            break;
          }
        }
        if (courseKey == null) continue;
  
        await _usersRef.child(uid).child("courses").child(courseKey).child("class").remove();
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
          final m = (entry.value is Map) ? Map<String, dynamic>.from(entry.value) : <String, dynamic>{};
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
  
        await _usersRef.child(uid).child("courses").child(courseKey).child("class").set(clsMini);
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
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text("Cancel")),
            ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text("Delete")),
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
            (cls["learners"] as Map).map((k, v) => MapEntry(k.toString(), v)),
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
  
      final sched = (cls["schedule"] is Map) ? Map<String, dynamic>.from(cls["schedule"]) : <String, dynamic>{};
      final sessions = (sched["sessions"] is List) ? List<dynamic>.from(sched["sessions"]) : <dynamic>[];
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
  
      bool hit = id.contains(_searchQuery) ||
          title.contains(_searchQuery) ||
          level.contains(_searchQuery) ||
          courseId.contains(_searchQuery) ||
          inst.contains(_searchQuery) ||
          status.contains(_searchQuery);
  
      if (hit) return true;
  
      // ✅ Search by learners (name / serial) inside cls["learners"]
      final learners = (cls["learners"] is Map) ? Map<dynamic, dynamic>.from(cls["learners"]) : null;
      if (learners == null || learners.isEmpty) return false;
  
      for (final entry in learners.entries) {
        final v = entry.value;
        if (v is Map) {
          final m = Map<String, dynamic>.from(v);
          final name = (m["name"] ?? "").toString().toLowerCase();
          final serial = (m["serial"] ?? "").toString().toLowerCase();
          if (name.contains(_searchQuery) || serial.contains(_searchQuery)) return true;
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
      final sched = (cls["schedule"] is Map) ? Map<String, dynamic>.from(cls["schedule"]) : <String, dynamic>{};
      final sessions = (sched["sessions"] is List) ? List<dynamic>.from(sched["sessions"]) : <dynamic>[];
      if (sessions.isEmpty) return "No schedule";
  
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
  
    Widget _pill({
      required String text,
      required Color color,
    }) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: color.withOpacity(0.12),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: color.withOpacity(0.35)),
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
      required String selectedCourseId,
      required Map<String, dynamic> selectedLearnersByUid,
      required StateSetter setModalState,
    }) async {
      if (_loadingLearners) {
        _notify("Learners are still loading...");
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
                        hintText: "Search by name or serial",
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
                              // ✅ FIX:
                              // - Block ONLY when trying to tick ON while not enrolled.
                              // - Always allow untick OFF (so you can remove if they got unenrolled later).
                              if (val == true && !isEnrolled) {
                                _notify("Not enrolled in this course. Assign course first.", error: true);
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
                                        : Colors.orange.withOpacity(0.12),
                                    border: Border.all(
                                      color: isEnrolled
                                          ? Colors.blue.withOpacity(0.35)
                                          : Colors.orange.withOpacity(0.35),
                                    ),
                                  ),
                                  child: Text(
                                    isEnrolled ? "Enrolled" : "Not enrolled",
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w900,
                                      color: isEnrolled ? Colors.blue : Colors.orange.shade800,
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
      if (_loadingCourses) return _notify("Courses are still loading...");
      if (_courses.isEmpty) return _notify("No courses found.", error: true);
  
      if (_loadingTeachers) return _notify("Teachers are still loading...");
      if (_teachers.isEmpty) return _notify("No teachers found.", error: true);
  
      final bool isEdit = existingClass != null;
  
      final String classId = isEdit ? (existingClass!["class_id"] ?? "").toString() : await _generateUniqueClassId();
  
      Map<String, dynamic> selectedCourse = _courses.first;
      if (isEdit) {
        final courseId = (existingClass!["course_id"] ?? "").toString();
        final found = _courses.where((c) => c["id"] == courseId).toList();
        if (found.isNotEmpty) selectedCourse = found.first;
      }
  
      bool isOpen = isEdit ? ((existingClass?["is_open"] ?? true) == true) : true;
  
      // Instructors from teachers list
      List<Map<String, String>> instructors = List<Map<String, String>>.from(_teachers);
      String instKey(Map<String, String> t) => (t["uid"] ?? "").trim();
  
      Map<String, String>? selectedInstructorObj = instructors.isNotEmpty ? instructors.first : null;
  
      if (isEdit) {
        final cur = existingClass!["instructor_current"];
        if (cur is Map) {
          final curMap = Map<String, dynamic>.from(cur);
          final curUid = (curMap["uid"] ?? "").toString().trim();
          final curName = (curMap["name"] ?? "").toString().trim().toLowerCase();
  
          if (curUid.isNotEmpty) {
            final found = instructors.where((t) => (t["uid"] ?? "") == curUid).toList();
            if (found.isNotEmpty) selectedInstructorObj = found.first;
          }
  
          if ((selectedInstructorObj == null || instKey(selectedInstructorObj!).isEmpty) && curName.isNotEmpty) {
            final found = instructors
                .where((t) => (t["name"] ?? "").toString().trim().toLowerCase() == curName)
                .toList();
            if (found.isNotEmpty) selectedInstructorObj = found.first;
          }
        } else {
          final exName = (existingClass!["instructor"] ?? "").toString().trim().toLowerCase();
          if (exName.isNotEmpty) {
            final found = instructors.where((t) => (t["name"] ?? "").toString().trim().toLowerCase() == exName).toList();
            if (found.isNotEmpty) selectedInstructorObj = found.first;
          }
        }
      }
  
      final String status = isEdit ? (existingClass!["status"] ?? "active").toString() : "active";
  
      final schedule = (isEdit && existingClass!["schedule"] is Map)
          ? Map<String, dynamic>.from(existingClass!["schedule"])
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
          final m = (item is Map) ? Map<String, dynamic>.from(item) : <String, dynamic>{};
          final row = _ScheduleRow(day: (m["day"] ?? "Mon").toString());
          row.startTime = (m["start_time"] ?? "").toString().isEmpty ? null : (m["start_time"] ?? "").toString();
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
  
      if (isEdit && existingClass!["learners"] is Map) {
        previousLearnersByUid = Map<String, dynamic>.from(
          (existingClass!["learners"] as Map).map((k, v) => MapEntry(k.toString(), v)),
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
          return StatefulBuilder(builder: (context, setModalState) {
            void setSaving(bool v) {
              saving = v;
              setModalState(() {});
            }
  
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
                              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(999),
                              color: Colors.black.withOpacity(0.06),
                            ),
                            child: Text(
                              "ID: $classId",
                              style: const TextStyle(fontWeight: FontWeight.w900),
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
                            border: Border.all(color: Colors.grey.withOpacity(0.35)),
                            color: Colors.grey.withOpacity(0.06),
                          ),
                          child: Text(
                            // ✅ Removed course_code in preview
                            "${courseLevel.isEmpty ? "" : "$courseLevel  "} ${courseTitle.isEmpty ? "-" : courseTitle}".trim(),
                            style: const TextStyle(fontWeight: FontWeight.w800),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        )
                      else
                        DropdownButtonFormField<Map<String, dynamic>>(
                          isExpanded: true,
                          value: selectedCourse,
                          decoration: const InputDecoration(
                            labelText: "Course",
                            border: OutlineInputBorder(),
                          ),
                          selectedItemBuilder: (context) {
                            return _courses.map((c) {
                              final lv = (c["level"] ?? "").toString();
                              final tt = (c["title"] ?? "").toString();
                              final label = "${lv.isEmpty ? "" : "$lv  "}$tt".trim();
                              return Align(
                                alignment: Alignment.centerLeft,
                                child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
                              );
                            }).toList();
                          },
                          items: _courses.map((c) {
                            final lv = (c["level"] ?? "").toString();
                            final tt = (c["title"] ?? "").toString();
                            final label = "${lv.isEmpty ? "" : "$lv  "}$tt".trim();
                            return DropdownMenuItem<Map<String, dynamic>>(
                              value: c,
                              child: SizedBox(
                                width: double.infinity,
                                child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
                              ),
                            );
                          }).toList(),
                          onChanged: saving
                              ? null
                              : (val) {
                            if (val == null) return;
                            setModalState(() {
                              selectedCourse = val;
                              instructors = List<Map<String, String>>.from(_teachers);
                              selectedInstructorObj = instructors.isNotEmpty ? instructors.first : null;
                              selectedLearnersByUid.clear();
                            });
                          },
                        ),
  
                      const SizedBox(height: 12),
  
                      DropdownButtonFormField<String>(
                        isExpanded: true,
                        value: selectedInstructorObj == null ? null : instKey(selectedInstructorObj!),
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
                            orElse: () => {"uid": "", "name": "", "serial": ""},
                          );
                          setModalState(() => selectedInstructorObj = t);
                        },
                      ),
  
                      const SizedBox(height: 12),
  
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.grey.withOpacity(0.35)),
                          color: Colors.grey.withOpacity(0.06),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                isOpen ? "Class is OPEN" : "Class is CLOSED",
                                style: const TextStyle(fontWeight: FontWeight.w900),
                              ),
                            ),
                            Switch(
                              value: isOpen,
                              onChanged: saving ? null : (v) => setModalState(() => isOpen = v),
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
  
                      OutlinedButton.icon(
                        onPressed: saving ? null : () => pickDate(setModalState),
                        icon: const Icon(Icons.event),
                        label: Text(
                          firstSessionDate == null ? "Pick first session date" : "First session: ${_formatDate(firstSessionDate!)}",
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
  
                      const SizedBox(height: 12),
  
                      OutlinedButton.icon(
                        onPressed: saving
                            ? null
                            : (!isOpen
                            ? null
                            : () => _openLearnersPickerStrict(
                          selectedCourseId: courseId,
                          selectedLearnersByUid: selectedLearnersByUid,
                          setModalState: setModalState,
                        )),
                        icon: const Icon(Icons.people_alt_rounded),
                        label: Text(
                          _loadingLearners
                              ? "Loading learners..."
                              : isOpen
                              ? (learnersCount == 0 ? "Pick learners" : "Learners selected: $learnersCount")
                              : (learnersCount == 0 ? "Learners (Closed)" : "Learners: $learnersCount (Closed)"),
                        ),
                      ),
  
                      const SizedBox(height: 16),
                      const Text(
                        "Weekly schedule",
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
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
                                    contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                                  ),
                                  child: DropdownButtonHideUnderline(
                                    child: DropdownButton<String>(
                                      value: _weekDays.contains(row.day) ? row.day : "Mon",
                                      isExpanded: true,
                                      items: _weekDays
                                          .map((d) => DropdownMenuItem<String>(
                                        value: d,
                                        child: Text(
                                          d,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(fontWeight: FontWeight.w800),
                                        ),
                                      ))
                                          .toList(),
                                      onChanged: saving
                                          ? null
                                          : (v) {
                                        if (v == null) return;
                                        setModalState(() => row.day = v);
                                      },
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: OutlinedButton(
                                  onPressed: saving ? null : () => pickTime(setModalState, row),
                                  child: Text(
                                    row.startTime == null ? "Start time" : row.startTime!,
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
                                    contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
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
                                  setModalState(() => scheduleRows.remove(row));
                                },
                                icon: const Icon(Icons.close),
                              ),
                            ],
                          ),
                        );
                      }),
  
                      OutlinedButton.icon(
                        onPressed: saving ? null : () => setModalState(() => scheduleRows.add(_ScheduleRow(day: "Mon"))),
                        icon: const Icon(Icons.add),
                        label: const Text("Add another day"),
                      ),
  
                      const SizedBox(height: 18),
  
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: saving
                              ? null
                              : () async {
                            final pickedUid = (selectedInstructorObj?["uid"] ?? "").trim();
                            final pickedName = (selectedInstructorObj?["name"] ?? "").trim();
  
                            if (pickedUid.isEmpty || pickedName.isEmpty) {
                              return _notify("Pick an instructor.", error: true);
                            }
  
                            final sessionsCount = int.tryParse(sessionsCountCtrl.text.trim());
                            if (sessionsCount == null || sessionsCount <= 0) {
                              return _notify("Sessions count invalid.", error: true);
                            }
  
                            if (firstSessionDate == null) {
                              return _notify("Pick the first session date.", error: true);
                            }
  
                            final sessions = <Map<String, dynamic>>[];
                            for (final row in scheduleRows) {
                              if (row.startTime == null) {
                                return _notify("Pick start time for ${row.day}.", error: true);
                              }
                              final dur = int.tryParse(row.durationCtrl.text.trim());
                              if (dur == null || dur <= 0) {
                                return _notify("Duration invalid for ${row.day}.", error: true);
                              }
                              sessions.add({"day": row.day, "start_time": row.startTime, "duration_min": dur});
                            }
  
                            final courseId = selectedCourse["id"].toString();
  
                            // ✅ FIX (so you NEVER get stuck):
                            // Auto-remove selected learners who are no longer enrolled.
                            final enrolledUids = _uidsWhoHaveCourse(courseId);
                            final removedAuto = <String>[];
                            final selectedUids = selectedLearnersByUid.keys.toList();
                            for (final uid in selectedUids) {
                              if (!enrolledUids.contains(uid)) {
                                selectedLearnersByUid.remove(uid);
                                removedAuto.add(uid);
                              }
                            }
                            if (removedAuto.isNotEmpty) {
                              _notify("Removed ${removedAuto.length} learner(s) (not enrolled anymore).");
                            }
  
                            final courseCode = (selectedCourse["course_code"] ?? "").toString();
                            final courseTitle = (selectedCourse["title"] ?? "").toString();
                            final courseDuration = (selectedCourse["duration"] ?? "").toString();
                            final courseLevel = (selectedCourse["level"] ?? "").toString();
                            final courseCategory = (selectedCourse["category"] ?? "").toString();
  
                            final oldCurrent = (isEdit && existingClass != null)
                                ? (existingClass!["instructor_current"] is Map
                                ? Map<String, dynamic>.from(existingClass!["instructor_current"])
                                : {
                              "uid": "",
                              "name": (existingClass!["instructor"] ?? "").toString(),
                              "serial": "",
                              "assignedAt": (existingClass!["updated_at"] ?? null),
                            })
                                : null;
  
                            final newCurrent = <String, dynamic>{
                              "uid": pickedUid,
                              "name": pickedName,
                              "serial": (selectedInstructorObj?["serial"] ?? "").toString(),
                              "assignedAt": ServerValue.timestamp,
                            };
  
                            final payload = <String, dynamic>{
                              "class_id": classId,
                              "status": status,
                              "is_open": isOpen,
  
                              "course_id": courseId,
                              "course_code": courseCode, // kept in DB (logic unchanged)
                              "course_title": courseTitle,
                              "course_duration": courseDuration,
                              "course_level": courseLevel,
                              "category": courseCategory,
  
                              "instructor": pickedName,
                              "instructor_current": newCurrent,
  
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
                              setSaving(true);
  
                              await _classesRef.child(classId).update(payload);
  
                              if (isEdit && oldCurrent != null) {
                                final oldUid = (oldCurrent["uid"] ?? "").toString().trim();
                                final newUid = (newCurrent["uid"] ?? "").toString().trim();
  
                                if (oldUid.isNotEmpty && oldUid != newUid) {
                                  final histRef = _classesRef.child(classId).child("instructor_history").push();
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
                                selectedLearnersByUid: selectedLearnersByUid,
                                previousLearnersByUid: previousLearnersByUid,
                              );
  
                              if (!mounted) return;
                              Navigator.pop(context);
                              _notify(isEdit ? "Saved: $classId" : "Class created: $classId");
                            } catch (e) {
                              _notify("Failed: $e", error: true);
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
          });
        },
      );
  
      await sheetFuture;
    }
  
    // -------------------- Classes List UI --------------------
  
    Widget _buildTopFilters() {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _searchCtrl,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              labelText: "Search (ID / course / instructor / learner)",
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
  
          // Day filter
          Row(
            children: [
              const Text("Day:", style: TextStyle(fontWeight: FontWeight.w900)),
              const SizedBox(width: 10),
              Expanded(
                child: DropdownButtonFormField<String>(
                  value: _dayFilter,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  ),
                  items: [
                    const DropdownMenuItem(value: "All", child: Text("All days")),
                    ..._weekDays.map((d) => DropdownMenuItem(value: d, child: Text(d))),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => _dayFilter = v);
                  },
                ),
              ),
            ],
          ),
  
          const SizedBox(height: 10),
  
          // Open / Closed filter chips
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ChoiceChip(
                label: const Text("All"),
                selected: _openFilter == null,
                onSelected: (_) => setState(() => _openFilter = null),
              ),
              ChoiceChip(
                label: const Text("Open only"),
                selected: _openFilter == true,
                onSelected: (_) => setState(() => _openFilter = true),
              ),
              ChoiceChip(
                label: const Text("Closed only"),
                selected: _openFilter == false,
                onSelected: (_) => setState(() => _openFilter = false),
              ),
            ],
          ),
        ],
      );
    }
  
    Widget _buildClassesList() {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildTopFilters(),
          const SizedBox(height: 12),
          Expanded(
            child: StreamBuilder<DatabaseEvent>(
              stream: _classesRef.onValue,
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
  
                final data = snap.data?.snapshot.value;
                if (data == null || data is! Map) {
                  return const Center(child: Text("No classes yet."));
                }
  
                final map = Map<dynamic, dynamic>.from(data);
  
                final allClasses = map.values.whereType<dynamic>().map((e) => Map<String, dynamic>.from(e as Map)).toList();
  
                final filtered = allClasses
                    .where(_matchesSearch)
                    .where(_matchesDayFilter)
                    .where(_matchesOpenFilter)
                    .toList();
  
                filtered.sort((a, b) {
                  final aa = (a["created_at"] ?? 0) is int ? (a["created_at"] as int) : 0;
                  final bb = (b["created_at"] ?? 0) is int ? (b["created_at"] as int) : 0;
                  return bb.compareTo(aa);
                });
  
                // Summary line
                final summary = "Showing ${filtered.length} of ${allClasses.length} classes";
  
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
                    Text(summary, style: TextStyle(color: Colors.grey.shade700, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 10),
                    Expanded(
                      child: ListView.separated(
                        padding: const EdgeInsets.only(bottom: 90),
                        itemCount: filtered.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (context, i) {
                          final cls = filtered[i];
  
                          final id = (cls["class_id"] ?? "").toString();
                          final status = (cls["status"] ?? "active").toString();
                          final bool isOpen = (cls["is_open"] ?? true) == true;
  
                          final courseTitle = (cls["course_title"] ?? "").toString();
                          final courseLevel = (cls["course_level"] ?? "").toString();
                          final courseId = (cls["course_id"] ?? "").toString();
  
                          final instructor = (cls["instructor"] ?? "").toString();
  
                          final sched = (cls["schedule"] is Map) ? Map<String, dynamic>.from(cls["schedule"]) : <String, dynamic>{};
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
                                      _pill(text: status.toUpperCase(), color: _statusColor(status)),
                                      const SizedBox(width: 8),
                                      _pill(text: isOpen ? "OPEN" : "CLOSED", color: _openColor(isOpen)),
                                    ],
                                  ),
                                  const SizedBox(height: 10),
  
                                  // ✅ ORDER YOU REQUESTED:
                                  // 1) class: level + title
                                  Text(
                                    "${courseLevel.isEmpty ? "" : "$courseLevel  "}${courseTitle.isEmpty ? "-" : courseTitle}".trim(),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontWeight: FontWeight.w900),
                                  ),
                                  const SizedBox(height: 6),
  
                              /*    // 2) course_id
                                  Text(
                                    "Course ID: ${courseId.isEmpty ? "-" : courseId}",
                                    style: TextStyle(color: Colors.grey.shade800, fontWeight: FontWeight.w700),
                                  ),
  
                                  const SizedBox(height: 6),*/
  
                                  // 3) rest
                                  Text(
                                    instructor.isEmpty ? "Instructor: -" : "Instructor: $instructor",
                                    style: TextStyle(color: Colors.grey.shade700, fontWeight: FontWeight.w600),
                                  ),
  
                                  const SizedBox(height: 4),
                                  Text(
                                    "Start: ${firstDate.isEmpty ? '-' : firstDate} • Sessions: ${sessionsCount.isEmpty ? '-' : sessionsCount} • Learners: $learnersCount",
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
  
    // -------------------- Build --------------------
  
    @override
    Widget build(BuildContext context) {
      return ScaffoldMessenger(
        key: _messengerKey,
        child: Scaffold(
          appBar: AppBar(title: const Text('Classes')),
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: _buildClassesList(),
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
  
  class _ScheduleRow {
    _ScheduleRow({required this.day});
    String day;
    String? startTime;
    final TextEditingController durationCtrl = TextEditingController(text: "90");
  }
