import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';

class AttendanceStatsScreen extends StatefulWidget {
  final Map<String, dynamic> classData;
  const AttendanceStatsScreen({super.key, required this.classData});

  @override
  State<AttendanceStatsScreen> createState() => _AttendanceStatsScreenState();
}

class _AttendanceStatsScreenState extends State<AttendanceStatsScreen> {
  // Brand Colors
  static const primaryBlue = Color(0xFF1A2B48);
  static const mainText = Color(0xFF2D2D2D);
  static const secondaryText = Color(0xFF636E72);
  static const appBg = Color(0xFFF8FAFC);
  static const uiBorder = Color(0xFFE2E8F0);

  // Status Colors
  static const successGreen = Color(0xFF10B981);
  static const warningOrange = Color(0xFFF59E0B);
  static const dangerRed = Color(0xFFEF4444);

  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  bool _busy = true;
  String? _error;
  DateTime? _month; // null = all months
  final Map<String, Map<String, dynamic>> _stats = {};
  final List<String> _availableMonths = []; // months that exist in DB like "2026-02"


  String get _classId => (widget.classData['class_id'] ?? widget.classData['id'] ?? '').toString();
  String get _courseTitle => (widget.classData['course_title'] ?? 'Course Stats').toString();

  @override
  void initState() {
    super.initState();
    _load();
  }

  // ... (Keeping your existing logic functions: _monthKey, _pickMonth, _userMini, _load) ...
  // Note: Just ensure they call setState as you originally had them.

  String _monthKey(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}';

  Future<void> _pickMonth() async {
    final now = DateTime.now();
    final months = <DateTime>[];

    // last 24 months including current
    for (int i = 0; i < 24; i++) {
      final dt = DateTime(now.year, now.month - i, 1);
      months.add(dt);
    }

    await showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) {
        return SafeArea(
          child: SizedBox(
            height: 420, // you can change height
            child: Column(
              children: [
                ListTile(
                  title: const Text("All months"),
                  leading: const Icon(Icons.all_inclusive),
                  onTap: () {
                    Navigator.pop(context);
                    setState(() => _month = null);
                    _load();
                  },
                ),
                const Divider(height: 0),
                Expanded(
                  child: ListView.builder(
                    itemCount: months.length,
                    itemBuilder: (context, index) {
                      final m = months[index];
                      final label = _monthKey(m);
                      return ListTile(
                        title: Text(label),
                        leading: const Icon(Icons.calendar_month),
                        onTap: () {
                          Navigator.pop(context);
                          setState(() => _month = m);
                          _load();
                        },
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
  }


  Future<void> _load() async {
    setState(() { _busy = true; _error = null; _stats.clear(); });
    try {
      final snap = await _db.child("classes").child(_classId).child('attendance').get();
      if (!snap.exists) { setState(() => _busy = false); return; }
      final selectedMonthKey = _month == null ? null : _monthKey(_month!);
      final raw = Map<String, dynamic>.from(snap.value as Map);

      for (final entry in raw.entries) {
        final rec = Map<String, dynamic>.from(entry.value as Map);
        final dateStr = (rec['date'] ?? '').toString();
        if (selectedMonthKey != null && !dateStr.startsWith(selectedMonthKey)) continue;

        final present = Map<String, dynamic>.from(rec['present'] ?? {});
        final absent = Map<String, dynamic>.from(rec['absent'] ?? {});
        final all = <String>{...present.keys.map((e)=>e.toString()), ...absent.keys.map((e)=>e.toString())};

        for (final uid in all) {
          _stats.putIfAbsent(uid, () => {'present': 0, 'total': 0, 'name': uid, 'serial': ''});
          _stats[uid]!['total'] = (_stats[uid]!['total'] as int) + 1;
        }
        for (final uid in present.keys) {
          _stats[uid]!['present'] = (_stats[uid]!['present'] as int) + 1;
        }
      }

      for (var uid in _stats.keys) {
        final snapU = await _db.child("users").child(uid).get();
        if (snapU.exists) {
          final m = Map<String, dynamic>.from(snapU.value as Map);
          _stats[uid]!['name'] = "${m['first_name'] ?? ''} ${m['last_name'] ?? ''}".trim();
          _stats[uid]!['serial'] = m['serial'] ?? '';
        }
      }
      setState(() => _busy = false);
    } catch (e) { setState(() { _error = e.toString(); _busy = false; }); }
  }

  Color _getHealthColor(int pct) {
    if (pct >= 80) return successGreen;
    if (pct >= 50) return warningOrange;
    return dangerRed;
  }

  @override
  Widget build(BuildContext context) {
    final rows = _stats.entries.map((e) {
      final m = e.value;
      final p = m['present'] as int;
      final t = m['total'] as int;
      final pct = t == 0 ? 0 : ((p / t) * 100).round();
      return {...m, 'pct': pct};
    }).toList()..sort((a, b) => (b['pct'] as int).compareTo(a['pct'] as int));

    return Scaffold(
      backgroundColor: appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
        title: Column(
          children: [
            const Text('Performance Stats', style: TextStyle(color: primaryBlue, fontSize: 16, fontWeight: FontWeight.bold)),
            Text(_courseTitle, style: const TextStyle(color: secondaryText, fontSize: 12)),
          ],
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            _buildFilterHeader(),
            Expanded(
              child: _busy
                  ? const Center(child: CircularProgressIndicator(color: primaryBlue))
                  : _error != null
                  ? SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Center(child: Text(_error!)),
              )
                  : rows.isEmpty
                  ? SingleChildScrollView(
                child: _buildEmptyState(),
              )
                  : _buildStatsList(rows),
            ),
          ],
        ),
      ),

    );
  }

  Widget _buildFilterHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      color: Colors.white,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text("Monthly Overview", style: TextStyle(fontWeight: FontWeight.w700, color: mainText)),
          InkWell(
            onTap: _pickMonth,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                border: Border.all(color: primaryBlue.withOpacity(0.2)),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.calendar_today_rounded, size: 14, color: primaryBlue),
                  const SizedBox(width: 8),
                  Text(
                    _month == null ? "All months" : _monthKey(_month!),
                    style: const TextStyle(color: primaryBlue, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatsList(List<Map<String, dynamic>> rows) {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: rows.length,
      itemBuilder: (context, i) {
        final r = rows[i];
        final pct = r['pct'] as int;
        final color = _getHealthColor(pct);

        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: uiBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(r['name'].toString(), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: mainText)),
                        if (r['serial'].toString().isNotEmpty)
                          Text("ID: ${r['serial']}", style: const TextStyle(color: secondaryText, fontSize: 12)),
                      ],
                    ),
                  ),
                  Text("$pct%", style: TextStyle(color: color, fontWeight: FontWeight.w900, fontSize: 18)),
                ],
              ),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: pct / 100,
                  minHeight: 8,
                  backgroundColor: color.withOpacity(0.1),
                  valueColor: AlwaysStoppedAnimation<Color>(color),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                "Attended ${r['present']} out of ${r['total']} sessions",
                style: const TextStyle(color: secondaryText, fontSize: 12, fontWeight: FontWeight.w500),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.analytics_outlined, size: 64, color: primaryBlue.withOpacity(0.1)),
            const SizedBox(height: 16),
            const Text(
              "No data for this month",
              textAlign: TextAlign.center,
              style: TextStyle(color: secondaryText, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }

}