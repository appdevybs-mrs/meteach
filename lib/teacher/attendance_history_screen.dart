import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'take_attendance_screen.dart';

class AttendanceHistoryScreen extends StatefulWidget {
  final Map<String, dynamic> classData;
  const AttendanceHistoryScreen({super.key, required this.classData});

  @override
  State<AttendanceHistoryScreen> createState() => _AttendanceHistoryScreenState();
}

class _AttendanceHistoryScreenState extends State<AttendanceHistoryScreen> {
  static const primaryBlue = Color(0xFF1A2B48);
  static const mainText = Color(0xFF2D2D2D);
  static const secondaryText = Color(0xFF636E72);
  static const appBg = Color(0xFFF8FAFC);
  static const presentGreen = Color(0xFF27AE60);
  static const absentRed = Color(0xFFEB5757);

  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  bool _busy = true;
  String? _error;
  List<Map<String, dynamic>> _sessions = [];

  String get _classId => (widget.classData['class_id'] ?? widget.classData['id'] ?? '').toString();
  String get _courseTitle => (widget.classData['course_title'] ?? 'Course History').toString();

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    setState(() { _busy = true; _error = null; });
    try {
      final snap = await _db.child("classes").child(_classId).child('attendance').get();
      if (!snap.exists) { setState(() => _busy = false); return; }

      final raw = Map<String, dynamic>.from(snap.value as Map);
      final list = raw.entries.map((e) => {'id': e.key, ...Map<String, dynamic>.from(e.value as Map)}).toList();

      // ✅ 1. Sort based on Date string (Descending: Newest Date first)
      list.sort((a, b) {
        String dateA = (a['date'] ?? '0000-00-00').toString();
        String dateB = (b['date'] ?? '0000-00-00').toString();
        return dateB.compareTo(dateA);
      });

      setState(() { _sessions = list; _busy = false; });
    } catch (e) { setState(() { _error = e.toString(); _busy = false; }); }
  }

  // ✅ 2. Delete Logic (Multi-location)
  Future<void> _deleteSession(Map<String, dynamic> session) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Record?'),
        content: const Text('This will remove attendance for the teacher and all learners. This action cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete', style: TextStyle(color: absentRed, fontWeight: FontWeight.bold))
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() => _busy = true);
    try {
      final sId = (session['sessionId'] ?? session['id']).toString();
      final Map<String, dynamic> updates = {};

      // Path 1: Remove from Class node
      updates['classes/$_classId/attendance/$sId'] = null;

      // Path 2: Remove from all Learners' course history
      final allUids = <String>{
        ...Map<String, dynamic>.from(session['present'] ?? {}).keys.map((e) => e.toString()),
        ...Map<String, dynamic>.from(session['absent'] ?? {}).keys.map((e) => e.toString()),
      };

      for (var uid in allUids) {
        final uSnap = await _db.child('users').child(uid).child('courses').get();
        if (uSnap.exists) {
          final courses = Map<String, dynamic>.from(uSnap.value as Map);
          for (var entry in courses.entries) {
            if (entry.value['class']?['class_id']?.toString() == _classId) {
              updates['users/$uid/courses/${entry.key}/attendance/$sId'] = null;
            }
          }
        }
      }

      await _db.update(updates);
      _loadHistory();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Record deleted successfully")));
    } catch (e) {
      setState(() { _error = "Delete failed: $e"; _busy = false; });
    }
  }

  Future<String> _nameOf(String uid) async {
    final snap = await _db.child("users").child(uid).get();
    if (!snap.exists) return uid;
    final m = Map<String, dynamic>.from(snap.value as Map);
    return "${m['first_name'] ?? ''} ${m['last_name'] ?? ''}".trim().isEmpty ? uid : "${m['first_name']} ${m['last_name']}";
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: appBg,
      appBar: AppBar(
        centerTitle: true,
        backgroundColor: Colors.white,
        elevation: 0,
        title: Column(
          children: [
            const Text('Attendance History', style: TextStyle(color: primaryBlue, fontSize: 16, fontWeight: FontWeight.bold)),
            Text(_courseTitle, style: const TextStyle(color: secondaryText, fontSize: 12)),
          ],
        ),
        actions: [
          IconButton(icon: const Icon(Icons.refresh_rounded, color: primaryBlue), onPressed: _busy ? null : _loadHistory),
        ],
      ),
      body: _busy
          ? const Center(child: CircularProgressIndicator(color: primaryBlue))
          : _error != null ? _buildError() : _sessions.isEmpty ? _buildEmpty() : _buildList(),
    );
  }

  Widget _buildList() {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      itemCount: _sessions.length,
      itemBuilder: (context, i) {
        final s = _sessions[i];
        final taughtTitle = (s['taught']?['title'] ?? 'Regular Session').toString();
        final presentCount = (s['present'] as Map? ?? {}).length;
        final absentCount = (s['absent'] as Map? ?? {}).length;

        return Container(
          margin: const EdgeInsets.only(bottom: 16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 10, offset: const Offset(0, 4))],
          ),
          child: ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            title: Text(s['date'] ?? 'No Date', style: const TextStyle(color: primaryBlue, fontWeight: FontWeight.w800, fontSize: 17)),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(taughtTitle, style: const TextStyle(color: mainText, fontWeight: FontWeight.w600, fontSize: 13)),
                const SizedBox(height: 8),
                Row(
                  children: [
                    _statBadge('${s['successRate']}%', Colors.blueGrey, Icons.insights),
                    const SizedBox(width: 8),
                    _statBadge('$presentCount', presentGreen, Icons.check_circle_outline),
                    const SizedBox(width: 8),
                    _statBadge('$absentCount', absentRed, Icons.highlight_off),
                  ],
                ),
              ],
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.edit_note_rounded, color: primaryBlue, size: 26),
                  onPressed: () => _editSession(s),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline_rounded, color: absentRed, size: 22),
                  onPressed: () => _deleteSession(s),
                ),
              ],
            ),
            children: [
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: _studentList('PRESENT', (s['present'] as Map? ?? {}).keys.toList(), presentGreen)),
                    Container(width: 1, height: 80, color: Colors.grey.withOpacity(0.2)),
                    Expanded(child: _studentList('ABSENT', (s['absent'] as Map? ?? {}).keys.toList(), absentRed)),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _statBadge(String label, Color color, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(6)),
      child: Row(
        children: [
          Icon(icon, size: 10, color: color),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 11)),
        ],
      ),
    );
  }

  Widget _studentList(String title, List<dynamic> uids, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 1.1)),
        const SizedBox(height: 8),
        if (uids.isEmpty) const Text('—', style: TextStyle(color: secondaryText))
        else ...uids.map((uid) => FutureBuilder<String>(
          future: _nameOf(uid.toString()),
          builder: (context, snap) => Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text(snap.data ?? '...', style: const TextStyle(fontSize: 12, color: mainText)),
          ),
        )),
      ],
    );
  }

  void _editSession(Map<String, dynamic> session) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => TakeAttendanceScreen(
      classData: widget.classData,
      existingSessionId: (session['sessionId'] ?? session['id']).toString(),
      existingRecord: session,
    )));
    _loadHistory();
  }

  Widget _buildEmpty() => const Center(child: Text('No attendance records found.', style: TextStyle(color: secondaryText)));
  Widget _buildError() => Center(child: Padding(padding: const EdgeInsets.all(20), child: Text('Error: $_error', textAlign: TextAlign.center, style: const TextStyle(color: absentRed))));
}