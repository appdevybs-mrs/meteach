import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

class TakeAttendanceScreen extends StatefulWidget {
  final Map<String, dynamic> classData;

  // ✅ Edit support:
  final String? existingSessionId;
  final Map<String, dynamic>? existingRecord;

  const TakeAttendanceScreen({
    super.key,
    required this.classData,
    this.existingSessionId,
    this.existingRecord,
  });

  @override
  State<TakeAttendanceScreen> createState() => _TakeAttendanceScreenState();
}

class _TakeAttendanceScreenState extends State<TakeAttendanceScreen> {
  static const primaryBlue = Color(0xFF1A2B48);
  static const actionOrange = Color(0xFFF98D28);
  static const mainText = Color(0xFF2D2D2D);
  static const appBg = Color(0xFFF4F7F9);
  static const uiBorder = Color(0xFFD1D9E0);

  static const String usersNode = "users";
  static const String classesNode = "classes";
  static const String syllabiNode = "syllabi";

  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  late final DatabaseReference _usersRef = _db.child(usersNode);
  late final DatabaseReference _classesRef = _db.child(classesNode);
  late final DatabaseReference _syllabiRef = _db.child(syllabiNode);

  bool _busy = true;
  String? _error;

  bool get _isEdit => widget.existingSessionId != null && widget.existingSessionId!.isNotEmpty;

  DateTime _date = DateTime.now();
  int _successRate = 80;

  List<Map<String, dynamic>> _syllabiSessions = [];
  Map<String, dynamic>? _selectedSession;

  final Map<String, bool> _present = {};
  List<String> _learnerUids = [];
  final Map<String, Map<String, dynamic>> _learnerInfo = {};

  // ✅ Homework fields
  final TextEditingController _homeworkCtrl = TextEditingController();
  String _homeworkDueDate = ''; // optional YYYY-MM-DD

  String get _classId => (widget.classData['class_id'] ?? widget.classData['id'] ?? '').toString();
  String get _courseId => (widget.classData['course_id'] ?? '').toString();
  String get _courseCode => (widget.classData['course_code'] ?? '').toString();
  String get _courseTitle => (widget.classData['course_title'] ?? '').toString();

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _homeworkCtrl.dispose();
    super.dispose();
  }

  DateTime? _parseDate(String s) {
    try {
      final parts = s.split('-');
      if (parts.length != 3) return null;
      final y = int.parse(parts[0]);
      final m = int.parse(parts[1]);
      final d = int.parse(parts[2]);
      return DateTime(y, m, d);
    } catch (_) {
      return null;
    }
  }

  // used for edit prefill
  String _pendingTaughtUnitId = '';
  String _pendingTaughtSessionId = '';

  Future<void> _init() async {
    setState(() {
      _busy = true;
      _error = null;
      _syllabiSessions = [];
      _selectedSession = null;
      _learnerUids = [];
      _present.clear();
      _learnerInfo.clear();
      _homeworkCtrl.text = '';
      _homeworkDueDate = '';
    });

    try {
      // learners from class node
      final learnersNode = widget.classData['learners'];
      final Set<String> learnerSet = {};
      if (learnersNode is Map) {
        learnerSet.addAll(learnersNode.keys.map((e) => e.toString()));
      }

      // If editing, include union of old present+absent too
      if (_isEdit && widget.existingRecord != null) {
        final rec = widget.existingRecord!;
        final p = (rec['present'] is Map) ? Map<String, dynamic>.from(rec['present'] as Map) : <String, dynamic>{};
        final a = (rec['absent'] is Map) ? Map<String, dynamic>.from(rec['absent'] as Map) : <String, dynamic>{};
        learnerSet.addAll(p.keys.map((e) => e.toString()));
        learnerSet.addAll(a.keys.map((e) => e.toString()));

        final dateStr = (rec['date'] ?? '').toString();
        final parsed = _parseDate(dateStr);
        if (parsed != null) _date = parsed;

        final sr = rec['successRate'];
        if (sr is num) _successRate = sr.toInt();

        // ✅ Homework prefill (safe if missing)
        final hw = (rec['homework'] is Map) ? Map<String, dynamic>.from(rec['homework'] as Map) : <String, dynamic>{};
        _homeworkCtrl.text = (hw['text'] ?? '').toString();
        _homeworkDueDate = (hw['dueDate'] ?? '').toString();

        // prefill present map
        for (final uid in learnerSet) {
          _present[uid] = false; // default absent
        }
        for (final uid in p.keys) {
          _present[uid.toString()] = true;
        }

        // prefill taught selection (match after loading syllabi list)
        final taught = (rec['taught'] is Map) ? Map<String, dynamic>.from(rec['taught'] as Map) : <String, dynamic>{};
        _pendingTaughtUnitId = (taught['unitId'] ?? '').toString();
        _pendingTaughtSessionId = (taught['sessionId'] ?? '').toString();
      } else {
        // create mode: default everyone present
        for (final uid in learnerSet) {
          _present[uid] = true;
        }
      }

      _learnerUids = learnerSet.toList()..sort();

      // Load learner small info
      await Future.wait(_learnerUids.map((uid) async {
        final snap = await _usersRef.child(uid).get();
        if (!snap.exists || snap.value == null) {
          _learnerInfo[uid] = {'uid': uid, 'name': uid, 'serial': ''};
          return;
        }
        final m = Map<String, dynamic>.from(snap.value as Map);
        final fn = (m['first_name'] ?? '').toString().trim();
        final ln = (m['last_name'] ?? '').toString().trim();
        final serial = (m['serial'] ?? '').toString().trim();
        _learnerInfo[uid] = {
          'uid': uid,
          'name': ('$fn $ln').trim().isEmpty ? uid : ('$fn $ln').trim(),
          'serial': serial,
        };
      }));

      // Load syllabi using course_id
      if (_courseId.isNotEmpty) {
        final sSnap = await _syllabiRef.child(_courseId).get();
        if (sSnap.exists && sSnap.value != null && sSnap.value is Map) {
          final s = Map<String, dynamic>.from(sSnap.value as Map);
          final units = s['units'];
          final List<Map<String, dynamic>> flat = [];

          if (units is List) {
            for (final u in units) {
              if (u is! Map) continue;
              final unit = Map<String, dynamic>.from(u);
              final unitId = (unit['id'] ?? '').toString();
              final unitTitle = (unit['title'] ?? '').toString();
              final sessions = unit['sessions'];

              if (sessions is List) {
                for (final ss in sessions) {
                  if (ss is! Map) continue;
                  final sess = Map<String, dynamic>.from(ss);
                  flat.add({
                    'unitId': unitId,
                    'unitTitle': unitTitle,
                    'sessionId': (sess['id'] ?? '').toString(),
                    'title': (sess['title'] ?? '').toString(),
                    'order': sess['order'] ?? 0,
                    'unitOrder': unit['order'] ?? 0,
                  });
                }
              }
            }
          }

          flat.sort((a, b) {
            int ai = (a['unitOrder'] is num) ? (a['unitOrder'] as num).toInt() : 0;
            int bi = (b['unitOrder'] is num) ? (b['unitOrder'] as num).toInt() : 0;
            if (ai != bi) return ai.compareTo(bi);
            int as = (a['order'] is num) ? (a['order'] as num).toInt() : 0;
            int bs = (b['order'] is num) ? (b['order'] as num).toInt() : 0;
            return as.compareTo(bs);
          });

          _syllabiSessions = flat;

          // ✅ Edit: match old taught
          if (_isEdit && _pendingTaughtUnitId.isNotEmpty && _pendingTaughtSessionId.isNotEmpty) {
            final match = _syllabiSessions.where((x) =>
            (x['unitId'] ?? '').toString() == _pendingTaughtUnitId &&
                (x['sessionId'] ?? '').toString() == _pendingTaughtSessionId);
            if (match.isNotEmpty) _selectedSession = match.first;
          }

          _selectedSession ??= _syllabiSessions.isNotEmpty ? _syllabiSessions.first : null;
        }
      }

      setState(() => _busy = false);
    } catch (e) {
      setState(() {
        _error = e.toString();
        _busy = false;
      });
    }
  }

  String _dateStr(DateTime d) {
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    return '${d.year}-$mm-$dd';
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _pickHomeworkDueDate() async {
    final init = _parseDate(_homeworkDueDate) ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: init,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => _homeworkDueDate = _dateStr(picked));
  }

  Future<Map<String, dynamic>?> _loadCoursesMap(String learnerUid) async {
    final snap = await _usersRef.child(learnerUid).child('courses').get();
    if (!snap.exists || snap.value == null || snap.value is! Map) return null;
    return Map<String, dynamic>.from(snap.value as Map);
  }

  Future<String?> _findLearnerCourseKeyForClass(String learnerUid, String classId) async {
    final courses = await _loadCoursesMap(learnerUid);
    if (courses == null) return null;

    for (final entry in courses.entries) {
      final courseKey = entry.key.toString();
      final courseVal = entry.value;
      if (courseVal is! Map) continue;
      final courseMap = Map<String, dynamic>.from(courseVal);
      final cls = courseMap['class'];
      if (cls is Map) {
        final clsMap = Map<String, dynamic>.from(cls);
        final cid = (clsMap['class_id'] ?? '').toString();
        if (cid == classId) return courseKey;
      }
    }
    return null;
  }

  Future<String> _loadTeacherName(String uid) async {
    final snap = await _usersRef.child(uid).get();
    if (!snap.exists || snap.value == null || snap.value is! Map) return '';
    final m = Map<String, dynamic>.from(snap.value as Map);
    final fn = (m['first_name'] ?? '').toString().trim();
    final ln = (m['last_name'] ?? '').toString().trim();
    return ('$fn $ln').trim();
  }

  Future<bool> _hasDuplicateForDate(String classId, String dateStr) async {
    final q = _classesRef.child(classId).child('attendance').orderByChild('date').equalTo(dateStr);
    final snap = await q.get();
    return snap.exists && snap.value != null;
  }

  Future<bool> _confirmDuplicateDialog() async {
    return (await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Attendance already exists'),
        content: const Text('You already took attendance for this class on this date.\n\nSave anyway?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save anyway')),
        ],
      ),
    )) ??
        false;
  }

  Future<void> _saveAttendance() async {
    if (_classId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Missing class_id')));
      return;
    }
    if (_selectedSession == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please select what was taught')));
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw Exception("Not logged in.");

      final dateStr = _dateStr(_date);

      // ✅ duplicate warning only in CREATE mode
      if (!_isEdit) {
        final dup = await _hasDuplicateForDate(_classId, dateStr);
        if (dup) {
          final proceed = await _confirmDuplicateDialog();
          if (!proceed) {
            setState(() => _busy = false);
            return;
          }
        }
      }

      final teacherName = await _loadTeacherName(user.uid);

      final sessionId = _isEdit ? widget.existingSessionId! : DateTime.now().millisecondsSinceEpoch.toString();

      final Map<String, bool> presentMap = {};
      final Map<String, bool> absentMap = {};
      for (final uid in _learnerUids) {
        final isPresent = _present[uid] ?? false;
        if (isPresent) {
          presentMap[uid] = true;
        } else {
          absentMap[uid] = true;
        }
      }

      final String hwText = _homeworkCtrl.text.trim();
      final String hwDue = _homeworkDueDate.trim();

      // Keep homework createdAt stable on edit (if existed)
      final prevHw = (widget.existingRecord?['homework'] is Map)
          ? Map<String, dynamic>.from(widget.existingRecord!['homework'] as Map)
          : <String, dynamic>{};

      final hwCreatedAt = prevHw['createdAt'] ?? (widget.existingRecord?['createdAt'] ?? ServerValue.timestamp);

      final Map<String, dynamic>? homeworkObj = (hwText.isEmpty && hwDue.isEmpty)
          ? null
          : {
        'text': hwText,
        if (hwDue.isNotEmpty) 'dueDate': hwDue,
        'createdAt': hwCreatedAt,
        'updatedAt': ServerValue.timestamp,
      };

      final classAttendancePath = '$classesNode/$_classId/attendance/$sessionId';

      final classRecord = {
        'sessionId': sessionId,
        'date': dateStr,
        'updatedAt': ServerValue.timestamp,
        'createdAt': widget.existingRecord?['createdAt'] ?? ServerValue.timestamp,
        'teacherUid': user.uid,
        'teacherName': teacherName,
        'course_id': _courseId,
        'course_code': _courseCode,
        'course_title': _courseTitle,
        'successRate': _successRate,
        'taught': {
          'unitId': _selectedSession!['unitId'],
          'unitTitle': _selectedSession!['unitTitle'],
          'sessionId': _selectedSession!['sessionId'],
          'title': _selectedSession!['title'],
        },
        if (homeworkObj != null) 'homework': homeworkObj, // ✅ add homework
        'present': presentMap,
        'absent': absentMap,
      };

      // Multi-location update (class + learners)
      final Map<String, dynamic> updates = {classAttendancePath: classRecord};

      // ✅ Update learners for ALL UIDs in this session
      final sessionUids = {...presentMap.keys, ...absentMap.keys}.toList();

      for (final learnerUid in sessionUids) {
        final courseKey = await _findLearnerCourseKeyForClass(learnerUid, _classId);
        if (courseKey == null) continue;

        final status = (_present[learnerUid] ?? false) ? 'present' : 'absent';
        final learnerPath = '$usersNode/$learnerUid/courses/$courseKey/attendance/$sessionId';

        updates[learnerPath] = {
          'sessionId': sessionId,
          'date': dateStr,
          'class_id': _classId,
          'course_id': _courseId,
          'course_code': _courseCode,
          'course_title': _courseTitle,
          'status': status,
          'successRate': _successRate,
          'taught': {
            'unitId': _selectedSession!['unitId'],
            'unitTitle': _selectedSession!['unitTitle'],
            'sessionId': _selectedSession!['sessionId'],
            'title': _selectedSession!['title'],
          },
          if (homeworkObj != null)
            'homework': {
              'text': hwText,
              if (hwDue.isNotEmpty) 'dueDate': hwDue,
            }, // ✅ copy to learner (lighter object)
          'updatedAt': ServerValue.timestamp,
          'createdAt': widget.existingRecord?['createdAt'] ?? ServerValue.timestamp,
        };
      }

      await _db.update(updates);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(_isEdit ? 'Attendance updated ✅' : 'Attendance saved ✅'),
      ));
      Navigator.pop(context);
    } catch (e) {
      setState(() {
        _error = e.toString();
        _busy = false;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: primaryBlue),
        title: Text(
          _isEdit ? 'Edit Attendance' : 'Take Attendance',
          style: const TextStyle(color: primaryBlue, fontWeight: FontWeight.w900),
        ),
      ),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error, fontWeight: FontWeight.w800),
            textAlign: TextAlign.center,
          ),
        ),
      )
          : ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            elevation: 0,
            color: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
              side: BorderSide(color: uiBorder.withOpacity(0.8)),
            ),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _courseTitle.isEmpty ? 'Class: $_classId' : _courseTitle,
                    style: const TextStyle(color: primaryBlue, fontWeight: FontWeight.w900, fontSize: 16),
                  ),
                  const SizedBox(height: 10),

                  Row(
                    children: [
                      Expanded(
                        child: Text('Date: ${_dateStr(_date)}',
                            style: const TextStyle(color: mainText, fontWeight: FontWeight.w800)),
                      ),
                      TextButton.icon(
                        onPressed: _pickDate,
                        icon: const Icon(Icons.calendar_month_rounded),
                        label: const Text('Change'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),

                  const Text('What was taught',
                      style: TextStyle(color: mainText, fontWeight: FontWeight.w900)),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: uiBorder.withOpacity(0.85)),
                      color: Colors.white,
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<Map<String, dynamic>>(
                        isExpanded: true,
                        value: _selectedSession,
                        items: _syllabiSessions.map((s) {
                          final label = '${s['unitTitle']} — ${s['title']}';
                          return DropdownMenuItem(
                            value: s,
                            child: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis),
                          );
                        }).toList(),
                        onChanged: (v) => setState(() => _selectedSession = v),
                      ),
                    ),
                  ),

                  const SizedBox(height: 14),
                  Text('Success Rate: $_successRate%',
                      style: const TextStyle(color: mainText, fontWeight: FontWeight.w900)),
                  Slider(
                    value: _successRate.toDouble(),
                    min: 0,
                    max: 100,
                    divisions: 20,
                    label: '$_successRate%',
                    onChanged: (v) => setState(() => _successRate = v.round()),
                  ),

                  const SizedBox(height: 10),

                  // ✅ Homework section
                  const Text('Homework',
                      style: TextStyle(color: mainText, fontWeight: FontWeight.w900)),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _homeworkCtrl,
                    minLines: 3,
                    maxLines: 6,
                    decoration: InputDecoration(
                      hintText: 'Write homework for learners...',
                      filled: true,
                      fillColor: Colors.white,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(color: uiBorder.withOpacity(0.85)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(color: actionOrange, width: 1.2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Due date: ${_homeworkDueDate.isEmpty ? '-' : _homeworkDueDate}',
                          style: TextStyle(color: mainText.withOpacity(0.75), fontWeight: FontWeight.w800),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _pickHomeworkDueDate,
                        icon: const Icon(Icons.event_available_rounded),
                        label: const Text('Set due date'),
                      ),
                      if (_homeworkDueDate.isNotEmpty)
                        IconButton(
                          tooltip: 'Clear due date',
                          onPressed: () => setState(() => _homeworkDueDate = ''),
                          icon: const Icon(Icons.clear_rounded),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 14),
          Row(
            children: [
              const Icon(Icons.people_alt_rounded, color: primaryBlue, size: 18),
              const SizedBox(width: 8),
              Text('Learners (${_learnerUids.length})',
                  style: const TextStyle(color: mainText, fontWeight: FontWeight.w900)),
            ],
          ),
          const SizedBox(height: 10),

          ..._learnerUids.map((uid) {
            final info = _learnerInfo[uid] ?? {'name': uid, 'serial': ''};
            final name = (info['name'] ?? uid).toString();
            final serial = (info['serial'] ?? '').toString();
            final isPresent = _present[uid] ?? false;

            return Container(
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: uiBorder.withOpacity(0.85)),
                color: Colors.white,
              ),
              child: SwitchListTile(
                value: isPresent,
                onChanged: (v) => setState(() => _present[uid] = v),
                title: Text(name, style: const TextStyle(color: mainText, fontWeight: FontWeight.w900)),
                subtitle: Text(
                  serial.isEmpty ? 'UID: $uid' : 'Serial: $serial',
                  style: TextStyle(color: mainText.withOpacity(0.7), fontWeight: FontWeight.w700),
                ),
                secondary: CircleAvatar(
                  backgroundColor: primaryBlue.withOpacity(0.08),
                  child: Icon(isPresent ? Icons.check_rounded : Icons.close_rounded, color: primaryBlue),
                ),
              ),
            );
          }).toList(),

          const SizedBox(height: 6),
          ElevatedButton.icon(
            icon: const Icon(Icons.save_rounded),
            label: Text(_isEdit ? 'Update Attendance' : 'Save Attendance'),
            style: ElevatedButton.styleFrom(
              backgroundColor: actionOrange,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            onPressed: _saveAttendance,
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
