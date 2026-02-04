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
    } catch (_) { return null; }
  }

  Future<void> _init() async {
    setState(() { _busy = true; _error = null; });
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

        for (final uid in learnerSet) _present[uid] = false;
        for (final uid in p.keys) _present[uid.toString()] = true;

        final taught = Map<String, dynamic>.from(rec['taught'] ?? {});
        _pendingTaughtUnitId = taught['unitId'] ?? '';
        _pendingTaughtSessionId = taught['sessionId'] ?? '';
      } else {
        for (final uid in learnerSet) _present[uid] = true;
      }

      _learnerUids = learnerSet.toList()..sort();

      await Future.wait(_learnerUids.map((uid) async {
        final snap = await _db.child('users').child(uid).get();
        if (!snap.exists) { _learnerInfo[uid] = {'uid': uid, 'name': uid, 'serial': ''}; return; }
        final m = Map<String, dynamic>.from(snap.value as Map);
        _learnerInfo[uid] = {
          'uid': uid,
          'name': "${m['first_name'] ?? ''} ${m['last_name'] ?? ''}".trim().isEmpty ? uid : "${m['first_name']} ${m['last_name']}".trim(),
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
                    'unitId': unit['id'], 'unitTitle': unit['title'],
                    'sessionId': sess['id'], 'title': sess['title'],
                    'order': sess['order'] ?? 0, 'unitOrder': unit['order'] ?? 0,
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
            final match = _syllabiSessions.where((x) => x['unitId'] == _pendingTaughtUnitId && x['sessionId'] == _pendingTaughtSessionId);
            if (match.isNotEmpty) _selectedSession = match.first;
          }
          _selectedSession ??= _syllabiSessions.isNotEmpty ? _syllabiSessions.first : null;
        }
      }
      setState(() => _busy = false);
    } catch (e) { setState(() { _error = e.toString(); _busy = false; }); }
  }

  // --- Date/Helper logic restored exactly as requested ---
  String _dateStr(DateTime d) => "${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}";

  Future<void> _pickDate() async {
    final picked = await showDatePicker(context: context, initialDate: _date, firstDate: DateTime(2020), lastDate: DateTime(2100));
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _pickHomeworkDueDate() async {
    final init = _parseDate(_homeworkDueDate) ?? DateTime.now();
    final picked = await showDatePicker(context: context, initialDate: init, firstDate: DateTime(2020), lastDate: DateTime(2100));
    if (picked != null) setState(() => _homeworkDueDate = _dateStr(picked));
  }

  // Multi-location Save logic (Restored fully)
  Future<void> _saveAttendance() async {
    if (_classId.isEmpty || _selectedSession == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please complete the form')));
      return;
    }
    setState(() { _busy = true; });
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw Exception("Not logged in");
      final dateStr = _dateStr(_date);

      if (!_isEdit) {
        final q = _db.child('classes').child(_classId).child('attendance').orderByChild('date').equalTo(dateStr);
        final snap = await q.get();
        if (snap.exists && !(await _confirmDuplicateDialog())) { setState(()=>_busy=false); return; }
      }

      final teacherSnap = await _db.child('users').child(user.uid).get();
      final tm = Map<String, dynamic>.from(teacherSnap.value as Map);
      final teacherName = "${tm['first_name'] ?? ''} ${tm['last_name'] ?? ''}".trim();

      final sessionId = _isEdit ? widget.existingSessionId! : DateTime.now().millisecondsSinceEpoch.toString();
      final Map<String, bool> presentMap = {};
      final Map<String, bool> absentMap = {};
      for (var uid in _learnerUids) { (_present[uid] ?? false) ? presentMap[uid] = true : absentMap[uid] = true; }

      final hwText = _homeworkCtrl.text.trim();
      final prevHw = Map<String, dynamic>.from(widget.existingRecord?['homework'] ?? {});
      final hwCreatedAt = prevHw['createdAt'] ?? (widget.existingRecord?['createdAt'] ?? ServerValue.timestamp);

      final Map<String, dynamic>? homeworkObj = (hwText.isEmpty && _homeworkDueDate.isEmpty) ? null : {
        'text': hwText, 'dueDate': _homeworkDueDate, 'createdAt': hwCreatedAt, 'updatedAt': ServerValue.timestamp,
      };

      final classRecord = {
        'sessionId': sessionId, 'date': dateStr, 'updatedAt': ServerValue.timestamp,
        'createdAt': widget.existingRecord?['createdAt'] ?? ServerValue.timestamp,
        'teacherUid': user.uid, 'teacherName': teacherName, 'course_id': _courseId,
        'course_code': _courseCode, 'course_title': _courseTitle, 'successRate': _successRate,
        'taught': { 'unitId': _selectedSession!['unitId'], 'unitTitle': _selectedSession!['unitTitle'], 'sessionId': _selectedSession!['sessionId'], 'title': _selectedSession!['title'] },
        'present': presentMap, 'absent': absentMap, if (homeworkObj != null) 'homework': homeworkObj,
      };

      final Map<String, dynamic> updates = {'classes/$_classId/attendance/$sessionId': classRecord};

      for (var lUid in _learnerUids) {
        final cSnap = await _db.child('users').child(lUid).child('courses').get();
        if (!cSnap.exists) continue;
        final courses = Map<String, dynamic>.from(cSnap.value as Map);
        String? targetKey;
        for (var entry in courses.entries) {
          if (entry.value['class']?['class_id']?.toString() == _classId) { targetKey = entry.key; break; }
        }
        if (targetKey != null) {
          updates['users/$lUid/courses/$targetKey/attendance/$sessionId'] = {
            ...classRecord, 'status': (_present[lUid] ?? false) ? 'present' : 'absent',
            'homework': homeworkObj != null ? {'text': hwText, 'dueDate': _homeworkDueDate} : null,
          };
        }
      }

      await _db.update(updates);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_isEdit ? 'Updated ✅' : 'Saved ✅')));
        Navigator.pop(context);
      }
    } catch (e) { setState(() { _error = e.toString(); _busy = false; }); }
  }

  Future<bool> _confirmDuplicateDialog() async {
    return (await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Duplicate Date'), content: const Text('Attendance already exists for this date. Save anyway?'),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')), ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save'))],
    ))) ?? false;
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
        title: Text(_isEdit ? 'Edit Session' : 'Take Attendance',
            style: const TextStyle(color: primaryBlue, fontWeight: FontWeight.w900)),
      ),
      body: _busy
          ? const Center(child: CircularProgressIndicator(color: primaryBlue))
          : _error != null ? _buildErrorState() : _buildForm(),
    );
  }

  Widget _buildForm() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _sectionLabel("LESSON DETAILS"),
        _buildLessonCard(),
        const SizedBox(height: 20),

        _sectionLabel("HOMEWORK & PROGRESS"),
        _buildHomeworkCard(),
        const SizedBox(height: 20),

        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _sectionLabel("LEARNERS"),
            Text("${_present.values.where((v)=>v).length}/${_learnerUids.length} Present",
                style: const TextStyle(color: primaryBlue, fontWeight: FontWeight.bold, fontSize: 12)),
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
          child: Text(_isEdit ? 'UPDATE SESSION' : 'SAVE ATTENDANCE',
              style: const TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1.1)),
        ),
        const SizedBox(height: 40),
      ],
    );
  }

  Widget _sectionLabel(String text) => Padding(
    padding: const EdgeInsets.only(left: 4, bottom: 8),
    child: Text(text, style: const TextStyle(color: secondaryText, fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 1.2)),
  );

  Widget _buildLessonCard() {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: uiBorder)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_courseTitle, style: const TextStyle(color: primaryBlue, fontWeight: FontWeight.w900, fontSize: 18)),
            const Divider(height: 24),
            Row(
              children: [
                const Icon(Icons.event, size: 20, color: primaryBlue),
                const SizedBox(width: 10),
                Expanded(child: Text('Date: ${_dateStr(_date)}', style: const TextStyle(fontWeight: FontWeight.bold))),
                TextButton(onPressed: _pickDate, child: const Text("Change")),
              ],
            ),
            const SizedBox(height: 10),
            const Text("Topic Taught", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: secondaryText)),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: uiBorder), color: appBg),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<Map<String, dynamic>>(
                  isExpanded: true,
                  value: _selectedSession,
                  items: _syllabiSessions.map((s) => DropdownMenuItem(value: s, child: Text("${s['unitTitle']} — ${s['title']}", style: const TextStyle(fontSize: 14)))).toList(),
                  onChanged: (v) => setState(() => _selectedSession = v),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHomeworkCard() {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: uiBorder)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text("Success Rate", style: TextStyle(fontWeight: FontWeight.bold)),
                Text("$_successRate%", style: const TextStyle(color: actionOrange, fontWeight: FontWeight.w900, fontSize: 16)),
              ],
            ),
            Slider(
              value: _successRate.toDouble(),
              min: 0, max: 100, divisions: 10,
              activeColor: actionOrange,
              onChanged: (v) => setState(() => _successRate = v.round()),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _homeworkCtrl,
              maxLines: 3,
              decoration: InputDecoration(
                hintText: "Enter homework details...",
                labelText: "Homework Instructions",
                filled: true, fillColor: appBg,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
              ),
            ),
            const SizedBox(height: 12),
            InkWell(
              onTap: _pickHomeworkDueDate,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: uiBorder)),
                child: Row(
                  children: [
                    const Icon(Icons.history_edu, size: 20, color: primaryBlue),
                    const SizedBox(width: 10),
                    Text(_homeworkDueDate.isEmpty ? "No Due Date" : "Due: $_homeworkDueDate", style: const TextStyle(fontWeight: FontWeight.bold)),
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
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: uiBorder)),
      child: ListTile(
        title: Text(info['name'], style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
        subtitle: Text(info['serial'].isEmpty ? "ID: $uid" : "Serial: ${info['serial']}", style: const TextStyle(fontSize: 12)),
        trailing: Switch(
          value: isPresent,
          activeColor: Colors.green,
          onChanged: (v) => setState(() => _present[uid] = v),
        ),
        leading: CircleAvatar(
          backgroundColor: isPresent ? Colors.green.withOpacity(0.1) : Colors.red.withOpacity(0.1),
          child: Icon(isPresent ? Icons.check : Icons.close, color: isPresent ? Colors.green : Colors.red, size: 20),
        ),
      ),
    );
  }

  Widget _buildErrorState() => Center(child: Text(_error!, style: const TextStyle(color: Colors.red)));
}