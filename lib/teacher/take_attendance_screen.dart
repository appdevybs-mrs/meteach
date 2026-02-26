import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

class TakeAttendanceScreen extends StatefulWidget {
  final Map<String, dynamic> classData;
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
  static const secondaryText = Color(0xFF64748B);
  static const appBg = Color(0xFFF4F7F9);
  static const uiBorder = Color(0xFFD1D9E0);

  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  bool _busy = true;
  String? _error;

  // Restore all your logic variables
  DateTime _date = DateTime.now();
  int _successRate = 80;
  List<Map<String, dynamic>> _syllabiSessions = [];
  Map<String, dynamic>? _selectedSession;
  final Map<String, bool> _present = {};
  List<String> _learnerUids = [];
  final Map<String, Map<String, dynamic>> _learnerInfo = {};
  final TextEditingController _homeworkCtrl = TextEditingController();
  String _homeworkDueDate = '';
  String _pendingTaughtUnitId = '';
  String _pendingTaughtSessionId = '';

  // NEW: prevents overwriting user edits to homework text
  bool _homeworkTouchedByUser = false;
  String _lastAutofilledHomework = '';
  bool get _isEdit => widget.existingSessionId != null && widget.existingSessionId!.isNotEmpty;
  String get _classId => (widget.classData['class_id'] ?? widget.classData['id'] ?? '').toString();
  String get _courseId => (widget.classData['course_id'] ?? '').toString();
  String get _courseCode => (widget.classData['course_code'] ?? '').toString();
  String get _courseTitle => (widget.classData['course_title'] ?? '').toString();

  @override
  void initState() {
    super.initState();
    _init(); // Restored your original init logic
  }

  @override
  void dispose() {
    _homeworkCtrl.dispose();
    super.dispose();
  }

  // --- START OF RESTORED ORIGINAL LOGIC ---

  DateTime? _parseDate(String s) {
    try {
      final parts = s.split('-');
      if (parts.length != 3) return null;
      return DateTime(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
    } catch (_) {
      return null;
    }
  }

  Future<void> _init() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final learnersNode = widget.classData['learners'];
      final Set<String> learnerSet = {};
      if (learnersNode is Map) learnerSet.addAll(learnersNode.keys.map((e) => e.toString()));

      if (_isEdit && widget.existingRecord != null) {
        final rec = widget.existingRecord!;
        final p = Map<String, dynamic>.from(rec['present'] ?? {});
        final a = Map<String, dynamic>.from(rec['absent'] ?? {});
        learnerSet.addAll(p.keys.map((e) => e.toString()));
        learnerSet.addAll(a.keys.map((e) => e.toString()));

        final parsed = _parseDate(rec['date'] ?? '');
        if (parsed != null) _date = parsed;
        if (rec['successRate'] is num) _successRate = rec['successRate'].toInt();

        final hw = Map<String, dynamic>.from(rec['homework'] ?? {});
        _homeworkCtrl.text = hw['text'] ?? '';
        _homeworkDueDate = hw['dueDate'] ?? '';

        // In edit mode, consider the loaded value as "owned"; don't auto-overwrite unless user clears it.
        _homeworkTouchedByUser = _homeworkCtrl.text.trim().isNotEmpty;

        for (final uid in learnerSet) _present[uid] = false;
        for (final uid in p.keys) _present[uid.toString()] = true;

        final taught = Map<String, dynamic>.from(rec['taught'] ?? {});
        _pendingTaughtUnitId = taught['unitId'] ?? '';
        _pendingTaughtSessionId = taught['sessionId'] ?? '';
      } else {
        for (final uid in learnerSet) _present[uid] = true;
        _homeworkTouchedByUser = false;
      }

      _learnerUids = learnerSet.toList()..sort();

      await Future.wait(_learnerUids.map((uid) async {
        final snap = await _db.child('users').child(uid).get();
        if (!snap.exists) {
          _learnerInfo[uid] = {'uid': uid, 'name': uid, 'serial': ''};
          return;
        }
        final m = Map<String, dynamic>.from(snap.value as Map);
        _learnerInfo[uid] = {
          'uid': uid,
          'name': "${m['first_name'] ?? ''} ${m['last_name'] ?? ''}".trim().isEmpty
              ? uid
              : "${m['first_name']} ${m['last_name']}".trim(),
          'serial': m['serial'] ?? '',
        };
      }));

      if (_courseId.isNotEmpty) {
        final sSnap = await _db.child('syllabi').child(_courseId).get();
        if (sSnap.exists) {
          final s = Map<String, dynamic>.from(sSnap.value as Map);
          final units = s['units'] as List?;
          final List<Map<String, dynamic>> flat = [];
          if (units != null) {
            for (var u in units) {
              final unit = Map<String, dynamic>.from(u);
              final sessions = unit['sessions'] as List?;
              if (sessions != null) {
                for (var ss in sessions) {
                  final sess = Map<String, dynamic>.from(ss);
                  flat.add({
                    'unitId': unit['id'],
                    'unitTitle': unit['title'],
                    'sessionId': sess['id'],
                    'title': sess['title'],
                    'order': sess['order'] ?? 0,
                    'unitOrder': unit['order'] ?? 0,

                    // NEW (UI-only data, does not affect saving structure)
                    'objective': (sess['objective'] ?? '').toString(),
                    'homework': (sess['homework'] ?? '').toString(),
                    'skillType': (sess['skillType'] ?? '').toString(),
                  });
                }
              }
            }
          }
          flat.sort((a, b) {
            int cmp = (a['unitOrder'] as int).compareTo(b['unitOrder'] as int);
            return cmp != 0 ? cmp : (a['order'] as int).compareTo(b['order'] as int);
          });
          _syllabiSessions = flat;

          if (_isEdit) {
            final match = _syllabiSessions.where((x) =>
            x['unitId'] == _pendingTaughtUnitId && x['sessionId'] == _pendingTaughtSessionId);
            if (match.isNotEmpty) _selectedSession = match.first;
          }

          _selectedSession ??= _syllabiSessions.isNotEmpty ? _syllabiSessions.first : null;

          // NEW: if not edit mode, and first selected has homework and box empty, auto-fill.
          if (!_isEdit && _selectedSession != null) {
            _applyHomeworkAutofillFromSelectedSession(_selectedSession!);
          }
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

  // --- Date/Helper logic restored exactly as requested ---
  String _dateStr(DateTime d) =>
      "${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}";

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

  // Multi-location Save logic (Restored fully)
  Future<void> _saveAttendance() async {
    if (_classId.isEmpty || _selectedSession == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please complete the form')));
      return;
    }
    setState(() {
      _busy = true;
    });
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw Exception("Not logged in");
      final dateStr = _dateStr(_date);

      if (!_isEdit) {
        final q = _db.child('classes').child(_classId).child('attendance').orderByChild('date').equalTo(dateStr);
        final snap = await q.get();
        if (snap.exists && !(await _confirmDuplicateDialog())) {
          setState(() => _busy = false);
          return;
        }
      }

      final teacherSnap = await _db.child('users').child(user.uid).get();
      final tm = Map<String, dynamic>.from(teacherSnap.value as Map);
      final teacherName = "${tm['first_name'] ?? ''} ${tm['last_name'] ?? ''}".trim();

      final sessionId = _isEdit ? widget.existingSessionId! : DateTime.now().millisecondsSinceEpoch.toString();
      final Map<String, bool> presentMap = {};
      final Map<String, bool> absentMap = {};
      for (var uid in _learnerUids) {
        (_present[uid] ?? false) ? presentMap[uid] = true : absentMap[uid] = true;
      }

      final hwText = _homeworkCtrl.text.trim();
      final prevHw = Map<String, dynamic>.from(widget.existingRecord?['homework'] ?? {});
      final hwCreatedAt = prevHw['createdAt'] ?? (widget.existingRecord?['createdAt'] ?? ServerValue.timestamp);

      final Map<String, dynamic>? homeworkObj = (hwText.isEmpty && _homeworkDueDate.isEmpty)
          ? null
          : {
        'text': hwText,
        'dueDate': _homeworkDueDate,
        'createdAt': hwCreatedAt,
        'updatedAt': ServerValue.timestamp,
      };

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
          'title': _selectedSession!['title']
        },
        'present': presentMap,
        'absent': absentMap,
        if (homeworkObj != null) 'homework': homeworkObj,
      };

      final Map<String, dynamic> updates = {'classes/$_classId/attendance/$sessionId': classRecord};

      for (var lUid in _learnerUids) {
        final cSnap = await _db.child('users').child(lUid).child('courses').get();
        if (!cSnap.exists) continue;
        final courses = Map<String, dynamic>.from(cSnap.value as Map);
        String? targetKey;
        for (final entry in courses.entries) {
          final val = entry.value;
          if (val is! Map) continue;

          final classNode = val['class'];
          if (classNode is! Map) continue;

          final cid = (classNode['class_id'] ?? '').toString();
          if (cid == _classId) {
            targetKey = entry.key.toString();
            break;
          }
        }
        if (targetKey != null) {
          updates['users/$lUid/courses/$targetKey/attendance/$sessionId'] = {
            ...classRecord,

            // ✅ CRITICAL: stamp the class so counts never mix across class changes
            'class_id': _classId,

            // (optional but nice for debugging / filtering)
            'course_id': _courseId,

            'status': (_present[lUid] ?? false) ? 'present' : 'absent',
            'homework': homeworkObj != null ? {'text': hwText, 'dueDate': _homeworkDueDate} : null,
          };
        }
      }

      await _db.update(updates);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_isEdit ? 'Updated ✅' : 'Saved ✅')));
        Navigator.pop(context);
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
        _busy = false;
      });
    }
  }

  Future<bool> _confirmDuplicateDialog() async {
    return (await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Duplicate Date'),
        content: const Text('Attendance already exists for this date. Save anyway?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    )) ??
        false;
  }

  // --- NEW: Topic selection (Option B) + Homework auto-fill ---

  void _applyHomeworkAutofillFromSelectedSession(Map<String, dynamic> session) {
    final hwFromSyllabus = (session['homework'] ?? '').toString().trim();
    if (hwFromSyllabus.isEmpty) return;

    final currentHw = _homeworkCtrl.text.trim();

    // If the user has typed anything manually, never overwrite.
    if (_homeworkTouchedByUser) return;

    // Allow overwrite if:
    // - the field is empty, OR
    // - the field still contains the previous auto-filled value
    if (currentHw.isEmpty || currentHw == _lastAutofilledHomework) {
      _homeworkCtrl.text = hwFromSyllabus;
      _lastAutofilledHomework = hwFromSyllabus;
    }
  }

  void _selectSession(Map<String, dynamic> session) {
    setState(() {
      _selectedSession = session;
    });

    // Auto-fill homework (editable) if present in syllabus and safe to do so.
    _applyHomeworkAutofillFromSelectedSession(session);
  }

  Future<void> _openTopicPickerSheet() async {
    if (_syllabiSessions.isEmpty) return;

    final chosen = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 44,
                  height: 5,
                  decoration: BoxDecoration(
                    color: uiBorder,
                    borderRadius: BorderRadius.circular(100),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: const [
                    Icon(Icons.menu_book, color: primaryBlue),
                    SizedBox(width: 10),
                    Text(
                      'Select Lesson Taught',
                      style: TextStyle(
                        color: primaryBlue,
                        fontWeight: FontWeight.w900,
                        fontSize: 16,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: _syllabiSessions.length,
                    separatorBuilder: (_, __) => const Divider(height: 12),
                    itemBuilder: (_, i) {
                      final s = _syllabiSessions[i];
                      final isSelected = _selectedSession != null &&
                          _selectedSession!['unitId'] == s['unitId'] &&
                          _selectedSession!['sessionId'] == s['sessionId'];

                      final unitTitle = (s['unitTitle'] ?? '').toString();
                      final title = (s['title'] ?? '').toString();
                      final objective = (s['objective'] ?? '').toString().trim();
                      final skillType = (s['skillType'] ?? '').toString().trim();
                      final hasHomework = (s['homework'] ?? '').toString().trim().isNotEmpty;

                      return InkWell(
                        onTap: () => Navigator.pop(ctx, s),
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: isSelected ? actionOrange : uiBorder),
                            color: isSelected ? actionOrange.withOpacity(0.06) : Colors.white,
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              CircleAvatar(
                                radius: 16,
                                backgroundColor: isSelected ? actionOrange.withOpacity(0.18) : appBg,
                                child: Icon(
                                  isSelected ? Icons.check : Icons.school,
                                  size: 18,
                                  color: isSelected ? actionOrange : primaryBlue,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    // Unit (small)
                                    Text(
                                      unitTitle,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: secondaryText,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    const SizedBox(height: 2),

                                    // Title (bold)
                                    Text(
                                      title,
                                      style: const TextStyle(
                                        color: primaryBlue,
                                        fontWeight: FontWeight.w900,
                                        fontSize: 14,
                                      ),
                                    ),

                                    if (objective.isNotEmpty) ...[
                                      const SizedBox(height: 6),
                                      Text(
                                        objective,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: mainText,
                                          fontSize: 12,
                                          height: 1.25,
                                        ),
                                      ),
                                    ],

                                    const SizedBox(height: 8),
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 8,
                                      children: [
                                        if (skillType.isNotEmpty)
                                          _chip(
                                            icon: Icons.category,
                                            text: skillType,
                                            tint: primaryBlue,
                                          ),
                                        if (hasHomework)
                                          _chip(
                                            icon: Icons.assignment_turned_in,
                                            text: 'Homework',
                                            tint: actionOrange,
                                          ),
                                      ],
                                    ),
                                  ],
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

    if (chosen != null) {
      _selectSession(chosen);
    }
  }

  Widget _chip({required IconData icon, required String text, required Color tint}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: tint.withOpacity(0.08),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: tint.withOpacity(0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: tint),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              color: tint,
              fontWeight: FontWeight.w800,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  // --- UI BUILDING ---

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
        title: Text(
          _isEdit ? 'Edit Session' : 'Take Attendance',
          style: const TextStyle(color: primaryBlue, fontWeight: FontWeight.w900),
        ),
      ),
      body: _busy
          ? const Center(child: CircularProgressIndicator(color: primaryBlue))
          : _error != null
          ? _buildErrorState()
          : _buildForm(),
    );
  }

  Widget _buildForm() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _sectionLabel("LESSON DETAILS"),
        _buildLessonCard(),
        const SizedBox(height: 20),

        _sectionLabel("HOMEWORK"),
        _buildHomeworkCard(),
        const SizedBox(height: 20),

        // ✅ MOVED HERE: Success rate above learners (UI-only move)
        _sectionLabel("PROGRESS"),
        _buildSuccessRateCard(),
        const SizedBox(height: 20),

        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _sectionLabel("LEARNERS"),
            Text(
              "${_present.values.where((v) => v).length}/${_learnerUids.length} Present",
              style: const TextStyle(color: primaryBlue, fontWeight: FontWeight.bold, fontSize: 12),
            ),
          ],
        ),
        ..._learnerUids.map((uid) => _buildLearnerTile(uid)),

        const SizedBox(height: 30),
        ElevatedButton(
          onPressed: _saveAttendance,
          style: ElevatedButton.styleFrom(
            backgroundColor: actionOrange,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: Text(
            _isEdit ? 'UPDATE SESSION' : 'SAVE ATTENDANCE',
            style: const TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1.1),
          ),
        ),
        const SizedBox(height: 40),
      ],
    );
  }

  // Slightly more “highlighted” section title
  Widget _sectionLabel(String text) => Padding(
    padding: const EdgeInsets.only(left: 4, bottom: 8),
    child: Row(
      children: [
        Container(
          width: 6,
          height: 14,
          decoration: BoxDecoration(
            color: actionOrange.withOpacity(0.9),
            borderRadius: BorderRadius.circular(99),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          text,
          style: const TextStyle(
            color: secondaryText,
            fontSize: 11,
            fontWeight: FontWeight.w900,
            letterSpacing: 1.2,
          ),
        ),
      ],
    ),
  );

  Widget _buildLessonCard() {
    final unitTitle = _selectedSession == null ? '' : (_selectedSession!['unitTitle'] ?? '').toString();
    final title = _selectedSession == null ? '' : (_selectedSession!['title'] ?? '').toString();
    final objective = _selectedSession == null ? '' : (_selectedSession!['objective'] ?? '').toString().trim();
    final skillType = _selectedSession == null ? '' : (_selectedSession!['skillType'] ?? '').toString().trim();
    final hasHomework =
        _selectedSession != null && (_selectedSession!['homework'] ?? '').toString().trim().isNotEmpty;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: uiBorder),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _courseTitle,
              style: const TextStyle(
                color: primaryBlue,
                fontWeight: FontWeight.w900,
                fontSize: 18,
              ),
            ),
            const Divider(height: 24),
            Row(
              children: [
                const Icon(Icons.event, size: 20, color: primaryBlue),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Date: ${_dateStr(_date)}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                TextButton(onPressed: _pickDate, child: const Text("Change")),
              ],
            ),
            const SizedBox(height: 14),

            // Stronger title/label
            const Text(
              "Topic Taught",
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w900,
                color: primaryBlue,
              ),
            ),
            const SizedBox(height: 8),

            // Replaces Dropdown: tap to open bottom sheet selector
            InkWell(
              onTap: _openTopicPickerSheet,
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: uiBorder),
                  color: appBg,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.menu_book, size: 20, color: primaryBlue),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _selectedSession == null
                          ? const Text(
                        "Select a lesson...",
                        style: TextStyle(color: secondaryText, fontWeight: FontWeight.w700),
                      )
                          : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            unitTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: secondaryText,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            title,
                            style: const TextStyle(
                              color: primaryBlue,
                              fontWeight: FontWeight.w900,
                              fontSize: 14,
                            ),
                          ),
                          if (objective.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Text(
                              objective,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: mainText,
                                fontSize: 12,
                                height: 1.25,
                              ),
                            ),
                          ],
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              if (skillType.isNotEmpty)
                                _chip(icon: Icons.category, text: skillType, tint: primaryBlue),
                              if (hasHomework)
                                _chip(icon: Icons.assignment_turned_in, text: 'Homework', tint: actionOrange),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Icon(Icons.keyboard_arrow_down, color: secondaryText),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ✅ NEW: Success Rate card moved out (UI-only; same slider/logic)
  Widget _buildSuccessRateCard() {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: uiBorder),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  "Success Rate",
                  style: TextStyle(fontWeight: FontWeight.w900, color: primaryBlue),
                ),
                Text(
                  "$_successRate%",
                  style: const TextStyle(color: actionOrange, fontWeight: FontWeight.w900, fontSize: 16),
                ),
              ],
            ),
            Slider(
              value: _successRate.toDouble(),
              min: 0,
              max: 100,
              divisions: 10,
              activeColor: actionOrange,
              onChanged: (v) => setState(() => _successRate = v.round()),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHomeworkCard() {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: uiBorder),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Homework text (editable always). We track user edits to avoid overwrites.
            TextField(
              controller: _homeworkCtrl,

              // ✅ 12 visible lines, then scrolls inside the field
              minLines: 12,
              maxLines: 12,
              keyboardType: TextInputType.multiline,

              onChanged: (v) {
                // If user types anything, lock auto-fill.
                if (v.trim().isNotEmpty && !_homeworkTouchedByUser) {
                  setState(() => _homeworkTouchedByUser = true);
                }

                // If user clears the field completely, allow auto-fill again.
                if (v.trim().isEmpty && _homeworkTouchedByUser) {
                  setState(() {
                    _homeworkTouchedByUser = false;
                    _lastAutofilledHomework = '';
                  });
                }
              },
              decoration: InputDecoration(
                hintText: "Enter homework details...",
                labelText: "Homework Instructions",
                labelStyle: const TextStyle(fontWeight: FontWeight.w800),
                filled: true,
                fillColor: appBg,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
              ),
            ),
            const SizedBox(height: 12),
            InkWell(
              onTap: _pickHomeworkDueDate,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: uiBorder),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.history_edu, size: 20, color: primaryBlue),
                    const SizedBox(width: 10),
                    Text(
                      _homeworkDueDate.isEmpty ? "No Due Date" : "Due: $_homeworkDueDate",
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const Spacer(),
                    const Icon(Icons.calendar_month, size: 18, color: secondaryText),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLearnerTile(String uid) {
    final info = _learnerInfo[uid] ?? {'name': uid, 'serial': ''};
    final isPresent = _present[uid] ?? false;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: uiBorder),
      ),
      child: ListTile(
        title: Text(
          info['name'],
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
        ),

        // ✅ Removed subtitle (serial/id) to make it tighter

        trailing: Switch(
          value: isPresent,
          activeColor: Colors.green,
          onChanged: (v) => setState(() => _present[uid] = v),
        ),
        leading: CircleAvatar(
          backgroundColor: isPresent ? Colors.green.withOpacity(0.1) : Colors.red.withOpacity(0.1),
          child: Icon(
            isPresent ? Icons.check : Icons.close,
            color: isPresent ? Colors.green : Colors.red,
            size: 20,
          ),
        ),
      ),
    );
  }

  Widget _buildErrorState() => Center(child: Text(_error!, style: const TextStyle(color: Colors.red)));
}