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
  static const appBg = Color(0xFFF4F7F9);
  static const uiBorder = Color(0xFFD1D9E0);

  static const String classesNode = "classes";
  static const String usersNode = "users";

  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  late final DatabaseReference _classesRef = _db.child(classesNode);
  late final DatabaseReference _usersRef = _db.child(usersNode);

  bool _busy = true;
  String? _error;

  List<Map<String, dynamic>> _sessions = [];

  String get _classId => (widget.classData['class_id'] ?? widget.classData['id'] ?? '').toString();
  String get _courseTitle => (widget.classData['course_title'] ?? '').toString();

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    setState(() {
      _busy = true;
      _error = null;
      _sessions = [];
    });

    try {
      final snap = await _classesRef.child(_classId).child('attendance').get();
      if (!snap.exists || snap.value == null) {
        setState(() => _busy = false);
        return;
      }

      final raw = Map<String, dynamic>.from(snap.value as Map);
      final list = raw.entries.map((e) {
        final m = (e.value is Map) ? Map<String, dynamic>.from(e.value as Map) : <String, dynamic>{};
        return {'id': e.key, ...m};
      }).toList();

      int numVal(dynamic v) => (v is num) ? v.toInt() : int.tryParse(v?.toString() ?? '') ?? 0;
      list.sort((a, b) {
        final ac = numVal(a['createdAt']);
        final bc = numVal(b['createdAt']);
        if (ac != bc) return bc.compareTo(ac);
        final ad = (a['date'] ?? '').toString();
        final bd = (b['date'] ?? '').toString();
        return bd.compareTo(ad);
      });

      setState(() {
        _sessions = list;
        _busy = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _busy = false;
      });
    }
  }

  Future<String> _nameOf(String uid) async {
    final snap = await _usersRef.child(uid).get();
    if (!snap.exists || snap.value == null || snap.value is! Map) return uid;
    final m = Map<String, dynamic>.from(snap.value as Map);
    final fn = (m['first_name'] ?? '').toString().trim();
    final ln = (m['last_name'] ?? '').toString().trim();
    final name = ('$fn $ln').trim();
    return name.isEmpty ? uid : name;
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
          _courseTitle.isEmpty ? 'Attendance History' : '$_courseTitle - History',
          style: const TextStyle(color: primaryBlue, fontWeight: FontWeight.w900),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded, color: primaryBlue),
            onPressed: _busy ? null : _loadHistory,
          )
        ],
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
          : _sessions.isEmpty
          ? const Center(
        child: Text('No attendance sessions yet.',
            style: TextStyle(color: mainText, fontWeight: FontWeight.w800)),
      )
          : ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _sessions.length,
        itemBuilder: (context, i) {
          final s = _sessions[i];
          final sessionId = (s['sessionId'] ?? s['id'] ?? '').toString();
          final date = (s['date'] ?? '').toString();
          final rate = (s['successRate'] ?? '').toString();
          final teacherName = (s['teacherName'] ?? '').toString();

          final taught = (s['taught'] is Map)
              ? Map<String, dynamic>.from(s['taught'] as Map)
              : <String, dynamic>{};
          final taughtTitle = (taught['title'] ?? '').toString();

          final present = (s['present'] is Map)
              ? Map<String, dynamic>.from(s['present'] as Map)
              : <String, dynamic>{};
          final absent = (s['absent'] is Map)
              ? Map<String, dynamic>.from(s['absent'] as Map)
              : <String, dynamic>{};

          return Card(
            elevation: 0,
            color: Colors.white,
            margin: const EdgeInsets.only(bottom: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
              side: BorderSide(color: uiBorder.withOpacity(0.8)),
            ),
            child: ExpansionTile(
              title: Row(
                children: [
                  Expanded(
                    child: Text(
                      date.isEmpty ? 'Session' : date,
                      style: const TextStyle(color: primaryBlue, fontWeight: FontWeight.w900),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Edit session',
                    icon: const Icon(Icons.edit_rounded, color: primaryBlue),
                    onPressed: () async {
                      await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => TakeAttendanceScreen(
                            classData: widget.classData,
                            existingSessionId: sessionId,
                            existingRecord: s,
                          ),
                        ),
                      );
                      // reload after edit
                      _loadHistory();
                    },
                  ),
                ],
              ),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (taughtTitle.isNotEmpty)
                      Text(taughtTitle,
                          style: const TextStyle(color: mainText, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 4),
                    Text(
                      'Success: ${rate.isEmpty ? '-' : '$rate%'} • Present: ${present.length} • Absent: ${absent.length}',
                      style: TextStyle(color: mainText.withOpacity(0.75), fontWeight: FontWeight.w700),
                    ),
                    if (teacherName.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text('Teacher: $teacherName',
                          style: TextStyle(color: mainText.withOpacity(0.7), fontWeight: FontWeight.w700)),
                    ],
                  ],
                ),
              ),
              childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              children: [
                const SizedBox(height: 8),
                const Text('Present', style: TextStyle(color: mainText, fontWeight: FontWeight.w900)),
                const SizedBox(height: 6),
                if (present.isEmpty)
                  Text('—', style: TextStyle(color: mainText.withOpacity(0.6), fontWeight: FontWeight.w700))
                else
                  ...present.keys.map((uid) => FutureBuilder<String>(
                    future: _nameOf(uid.toString()),
                    builder: (_, snap) => Text(
                      '• ${snap.data ?? uid}',
                      style: TextStyle(color: mainText.withOpacity(0.85), fontWeight: FontWeight.w700),
                    ),
                  )),
                const SizedBox(height: 10),
                const Text('Absent', style: TextStyle(color: mainText, fontWeight: FontWeight.w900)),
                const SizedBox(height: 6),
                if (absent.isEmpty)
                  Text('—', style: TextStyle(color: mainText.withOpacity(0.6), fontWeight: FontWeight.w700))
                else
                  ...absent.keys.map((uid) => FutureBuilder<String>(
                    future: _nameOf(uid.toString()),
                    builder: (_, snap) => Text(
                      '• ${snap.data ?? uid}',
                      style: TextStyle(color: mainText.withOpacity(0.85), fontWeight: FontWeight.w700),
                    ),
                  )),
              ],
            ),
          );
        },
      ),
    );
  }
}
