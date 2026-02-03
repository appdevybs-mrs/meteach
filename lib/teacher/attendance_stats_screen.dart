import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';

class AttendanceStatsScreen extends StatefulWidget {
  final Map<String, dynamic> classData;
  const AttendanceStatsScreen({super.key, required this.classData});

  @override
  State<AttendanceStatsScreen> createState() => _AttendanceStatsScreenState();
}

class _AttendanceStatsScreenState extends State<AttendanceStatsScreen> {
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

  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month, 1);

  // uid -> {present, total, name, serial}
  final Map<String, Map<String, dynamic>> _stats = {};

  String get _classId => (widget.classData['class_id'] ?? widget.classData['id'] ?? '').toString();
  String get _courseTitle => (widget.classData['course_title'] ?? '').toString();

  @override
  void initState() {
    super.initState();
    _load();
  }

  String _monthKey(DateTime d) {
    final mm = d.month.toString().padLeft(2, '0');
    return '${d.year}-$mm';
  }

  Future<void> _pickMonth() async {
    // Using normal date picker; we only use year+month
    final picked = await showDatePicker(
      context: context,
      initialDate: _month,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() => _month = DateTime(picked.year, picked.month, 1));
      _load();
    }
  }

  Future<Map<String, dynamic>> _userMini(String uid) async {
    final snap = await _usersRef.child(uid).get();
    if (!snap.exists || snap.value == null || snap.value is! Map) {
      return {'name': uid, 'serial': ''};
    }
    final m = Map<String, dynamic>.from(snap.value as Map);
    final fn = (m['first_name'] ?? '').toString().trim();
    final ln = (m['last_name'] ?? '').toString().trim();
    final serial = (m['serial'] ?? '').toString().trim();
    final name = ('$fn $ln').trim();
    return {'name': name.isEmpty ? uid : name, 'serial': serial};
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
      _stats.clear();
    });

    try {
      final snap = await _classesRef.child(_classId).child('attendance').get();
      if (!snap.exists || snap.value == null || snap.value is! Map) {
        setState(() => _busy = false);
        return;
      }

      final monthKey = _monthKey(_month);

      final raw = Map<String, dynamic>.from(snap.value as Map);

      // Pass 1: count totals and presents
      for (final entry in raw.entries) {
        final rec = (entry.value is Map) ? Map<String, dynamic>.from(entry.value as Map) : <String, dynamic>{};
        final date = (rec['date'] ?? '').toString();
        if (!date.startsWith(monthKey)) continue;

        final present = (rec['present'] is Map) ? Map<String, dynamic>.from(rec['present'] as Map) : <String, dynamic>{};
        final absent = (rec['absent'] is Map) ? Map<String, dynamic>.from(rec['absent'] as Map) : <String, dynamic>{};

        final allUids = <String>{...present.keys.map((e) => e.toString()), ...absent.keys.map((e) => e.toString())};

        for (final uid in allUids) {
          _stats.putIfAbsent(uid, () => {'present': 0, 'total': 0, 'name': uid, 'serial': ''});
          _stats[uid]!['total'] = (_stats[uid]!['total'] as int) + 1;
        }
        for (final uid in present.keys.map((e) => e.toString())) {
          _stats.putIfAbsent(uid, () => {'present': 0, 'total': 0, 'name': uid, 'serial': ''});
          _stats[uid]!['present'] = (_stats[uid]!['present'] as int) + 1;
        }
      }

      // Pass 2: load names/serials
      await Future.wait(_stats.keys.map((uid) async {
        final mini = await _userMini(uid);
        _stats[uid]!['name'] = mini['name'];
        _stats[uid]!['serial'] = mini['serial'];
      }));

      setState(() => _busy = false);
    } catch (e) {
      setState(() {
        _error = e.toString();
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final monthLabel = _monthKey(_month);

    // Convert to list sorted by % desc
    final rows = _stats.entries.map((e) {
      final uid = e.key;
      final m = e.value;
      final present = (m['present'] as int?) ?? 0;
      final total = (m['total'] as int?) ?? 0;
      final pct = total == 0 ? 0 : ((present / total) * 100).round();
      return {
        'uid': uid,
        'name': (m['name'] ?? uid).toString(),
        'serial': (m['serial'] ?? '').toString(),
        'present': present,
        'total': total,
        'pct': pct,
      };
    }).toList()
      ..sort((a, b) => (b['pct'] as int).compareTo(a['pct'] as int));

    return Scaffold(
      backgroundColor: appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: primaryBlue),
        title: Text(
          _courseTitle.isEmpty ? 'Attendance Stats' : '$_courseTitle - Stats',
          style: const TextStyle(color: primaryBlue, fontWeight: FontWeight.w900),
        ),
        actions: [
          TextButton.icon(
            onPressed: _pickMonth,
            icon: const Icon(Icons.calendar_month_rounded, color: primaryBlue),
            label: Text(monthLabel, style: const TextStyle(color: primaryBlue, fontWeight: FontWeight.w800)),
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
          : rows.isEmpty
          ? Center(
        child: Text(
          'No attendance records for $monthLabel.',
          style: const TextStyle(color: mainText, fontWeight: FontWeight.w800),
        ),
      )
          : ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: rows.length,
        itemBuilder: (_, i) {
          final r = rows[i];
          return Card(
            elevation: 0,
            color: Colors.white,
            margin: const EdgeInsets.only(bottom: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
              side: BorderSide(color: uiBorder.withOpacity(0.8)),
            ),
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: primaryBlue.withOpacity(0.08),
                child: Text('${r['pct']}%',
                    style: const TextStyle(color: primaryBlue, fontWeight: FontWeight.w900)),
              ),
              title: Text(
                r['name'].toString(),
                style: const TextStyle(color: mainText, fontWeight: FontWeight.w900),
              ),
              subtitle: Text(
                [
                  if ((r['serial'] as String).isNotEmpty) 'Serial: ${r['serial']}',
                  'Present: ${r['present']}/${r['total']}',
                ].join(' • '),
                style: TextStyle(color: mainText.withOpacity(0.7), fontWeight: FontWeight.w700),
              ),
            ),
          );
        },
      ),
    );
  }
}
