import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';

import '../shared/app_theme.dart';
import '../shared/human_error.dart';
import '../shared/teacher_tour_guide.dart';

class AttendanceStatsScreen extends StatefulWidget {
  final Map<String, dynamic> classData;

  const AttendanceStatsScreen({super.key, required this.classData});

  @override
  State<AttendanceStatsScreen> createState() => _AttendanceStatsScreenState();
}

class _AttendanceStatsScreenState extends State<AttendanceStatsScreen> {
  static const Color successGreen = Color(0xFF10B981);
  static const Color warningOrange = Color(0xFFF59E0B);
  static const Color dangerRed = Color(0xFFEF4444);

  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  bool _busy = true;
  String? _error;
  DateTime? _month; // null = all months

  final Map<String, Map<String, dynamic>> _stats = {};
  final List<String> _availableMonths = [];

  String get _classId =>
      (widget.classData['class_id'] ?? widget.classData['id'] ?? '').toString();

  String get _courseTitle =>
      (widget.classData['course_title'] ?? 'Course Stats').toString();

  AppPalette get palette => appThemeController.palette;

  @override
  void initState() {
    super.initState();
    appThemeController.addListener(_onThemeChanged);
    _load();
  }

  @override
  void dispose() {
    appThemeController.removeListener(_onThemeChanged);
    super.dispose();
  }

  void _onThemeChanged() {
    if (!mounted) return;
    setState(() {});
  }

  String _monthKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}';

  String _monthLabel(String key) {
    final parts = key.split('-');
    if (parts.length != 2) return key;

    final year = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);

    if (year == null || month == null || month < 1 || month > 12) return key;

    const monthNames = [
      '',
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];

    return '${monthNames[month]} $year';
  }

  Future<void> _pickMonth() async {
    final p = palette;

    await showModalBottomSheet(
      context: context,
      backgroundColor: p.appBg,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (_) {
        return SafeArea(
          child: SizedBox(
            height: 460,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Choose Period',
                    style: TextStyle(
                      color: p.primary,
                      fontWeight: FontWeight.w900,
                      fontSize: 18,
                    ),
                  ),
                  const SizedBox(height: 12),
                  InkWell(
                    borderRadius: BorderRadius.circular(18),
                    onTap: () {
                      Navigator.pop(context);
                      setState(() => _month = null);
                      _load();
                    },
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: p.cardBg,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: p.border.withValues(alpha: 0.9)),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(
                              color: p.soft,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Icon(
                              Icons.all_inclusive_rounded,
                              color: p.primary,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'All months',
                              style: TextStyle(
                                color: p.primary,
                                fontWeight: FontWeight.w900,
                                fontSize: 14,
                              ),
                            ),
                          ),
                          if (_month == null)
                            Icon(Icons.check_circle_rounded, color: p.accent),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: _availableMonths.isEmpty
                        ? Center(
                            child: Text(
                              'No saved months found yet.',
                              style: TextStyle(
                                color: p.text.withValues(alpha: 0.7),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          )
                        : ListView.separated(
                            itemCount: _availableMonths.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 10),
                            itemBuilder: (context, index) {
                              final key = _availableMonths[index];
                              final isSelected =
                                  _month != null && _monthKey(_month!) == key;

                              return InkWell(
                                borderRadius: BorderRadius.circular(18),
                                onTap: () {
                                  final parts = key.split('-');
                                  final year = int.tryParse(parts[0]) ?? 2000;
                                  final month = int.tryParse(parts[1]) ?? 1;

                                  Navigator.pop(context);
                                  setState(() {
                                    _month = DateTime(year, month, 1);
                                  });
                                  _load();
                                },
                                child: Container(
                                  padding: const EdgeInsets.all(14),
                                  decoration: BoxDecoration(
                                    color: p.cardBg,
                                    borderRadius: BorderRadius.circular(18),
                                    border: Border.all(
                                      color: isSelected
                                          ? p.primary
                                          : p.border.withValues(alpha: 0.9),
                                      width: isSelected ? 1.5 : 1,
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Container(
                                        width: 42,
                                        height: 42,
                                        decoration: BoxDecoration(
                                          color: p.primary.withValues(alpha: 0.08),
                                          borderRadius: BorderRadius.circular(
                                            14,
                                          ),
                                        ),
                                        child: Icon(
                                          Icons.calendar_month_rounded,
                                          color: p.primary,
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              _monthLabel(key),
                                              style: TextStyle(
                                                color: p.primary,
                                                fontWeight: FontWeight.w900,
                                                fontSize: 14,
                                              ),
                                            ),
                                            const SizedBox(height: 3),
                                            Text(
                                              key,
                                              style: TextStyle(
                                                color: p.text.withValues(alpha: 0.6),
                                                fontWeight: FontWeight.w700,
                                                fontSize: 12,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      if (isSelected)
                                        Icon(
                                          Icons.check_circle_rounded,
                                          color: p.accent,
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
          ),
        );
      },
    );
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
      _stats.clear();
      _availableMonths.clear();
    });

    try {
      final snap = await _db
          .child("classes")
          .child(_classId)
          .child('attendance')
          .get();

      if (!snap.exists) {
        setState(() => _busy = false);
        return;
      }

      final selectedMonthKey = _month == null ? null : _monthKey(_month!);
      final raw = Map<String, dynamic>.from(snap.value as Map);

      final monthSet = <String>{};

      for (final entry in raw.entries) {
        if (entry.value is! Map) continue;

        final rec = Map<String, dynamic>.from(entry.value as Map);
        final dateStr = (rec['date'] ?? '').toString();

        if (dateStr.length >= 7) {
          monthSet.add(dateStr.substring(0, 7));
        }

        if (selectedMonthKey != null && !dateStr.startsWith(selectedMonthKey)) {
          continue;
        }

        final present = Map<String, dynamic>.from(rec['present'] ?? {});
        final absent = Map<String, dynamic>.from(rec['absent'] ?? {});
        final all = <String>{
          ...present.keys.map((e) => e.toString()),
          ...absent.keys.map((e) => e.toString()),
        };

        for (final uid in all) {
          _stats.putIfAbsent(
            uid,
            () => {
              'present': 0,
              'absent': 0,
              'total': 0,
              'name': uid,
              'serial': '',
            },
          );

          _stats[uid]!['total'] = (_stats[uid]!['total'] as int) + 1;
        }

        for (final uid in present.keys) {
          _stats[uid.toString()]!['present'] =
              (_stats[uid.toString()]!['present'] as int) + 1;
        }

        for (final uid in absent.keys) {
          _stats[uid.toString()]!['absent'] =
              (_stats[uid.toString()]!['absent'] as int) + 1;
        }
      }

      final monthsSorted = monthSet.toList()..sort((a, b) => b.compareTo(a));
      _availableMonths.addAll(monthsSorted);

      for (final uid in _stats.keys) {
        final snapU = await _db.child("users").child(uid).get();
        if (snapU.exists) {
          final m = Map<String, dynamic>.from(snapU.value as Map);
          final fullName = "${m['first_name'] ?? ''} ${m['last_name'] ?? ''}"
              .trim();

          _stats[uid]!['name'] = fullName.isEmpty ? uid : fullName;
          _stats[uid]!['serial'] = (m['serial'] ?? '').toString();
        }
      }

      setState(() => _busy = false);
    } catch (e) {
      setState(() {
        _error = toHumanError(e);
        _busy = false;
      });
    }
  }

  Color _getHealthColor(int pct) {
    if (pct >= 80) return successGreen;
    if (pct >= 50) return warningOrange;
    return dangerRed;
  }

  String _healthLabel(int pct) {
    if (pct >= 90) return 'Excellent';
    if (pct >= 80) return 'Strong';
    if (pct >= 65) return 'Fair';
    if (pct >= 50) return 'Watch';
    return 'At Risk';
  }

  IconData _healthIcon(int pct) {
    if (pct >= 80) return Icons.trending_up_rounded;
    if (pct >= 50) return Icons.remove_red_eye_rounded;
    return Icons.warning_amber_rounded;
  }

  @override
  Widget build(BuildContext context) {
    final p = palette;

    TeacherTourGuide.schedule(
      context,
      screenId: 'teacher_attendance_stats',
      hints: const [
        TeacherTourHint(
          title: 'Attendance statistics',
          line: 'Use this page to track attendance performance and risk levels per learner.',
        ),
      ],
    );

    final rows =
        _stats.entries.map((e) {
          final m = e.value;
          final present = m['present'] as int;
          final absent = m['absent'] as int;
          final total = m['total'] as int;
          final pct = total == 0 ? 0 : ((present / total) * 100).round();

          return {
            ...m,
            'uid': e.key,
            'present': present,
            'absent': absent,
            'total': total,
            'pct': pct,
          };
        }).toList()..sort((a, b) {
          final pctCompare = (b['pct'] as int).compareTo(a['pct'] as int);
          if (pctCompare != 0) return pctCompare;
          return (a['name'] ?? '').toString().toLowerCase().compareTo(
            (b['name'] ?? '').toString().toLowerCase(),
          );
        });

    final learnersCount = rows.length;
    final avgPct = rows.isEmpty
        ? 0
        : (rows.fold<int>(0, (sum, r) => sum + (r['pct'] as int)) / rows.length)
              .round();
    final atRiskCount = rows.where((r) => (r['pct'] as int) < 50).length;
    final excellentCount = rows.where((r) => (r['pct'] as int) >= 80).length;

    return Scaffold(
      backgroundColor: p.appBg,
      appBar: AppBar(
        backgroundColor: p.cardBg,
        elevation: 0,
        centerTitle: false,
        surfaceTintColor: p.cardBg,
        titleSpacing: 16,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Attendance Stats',
              style: TextStyle(
                color: p.primary,
                fontSize: 16,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              _courseTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: p.text.withValues(alpha: 0.72),
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: Icon(Icons.refresh_rounded, color: p.primary),
            onPressed: _busy ? null : _load,
          ),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: Opacity(
                opacity: 0.04,
                child: Center(
                  child: Icon(
                    Icons.analytics_rounded,
                    size: 220,
                    color: p.primary.withValues(alpha: 0.12),
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            child: _busy
                ? Center(child: CircularProgressIndicator(color: p.primary))
                : _error != null
                ? _buildErrorState(p)
                : rows.isEmpty
                ? _buildEmptyState(p)
                : RefreshIndicator(
                    color: p.primary,
                    onRefresh: _load,
                    child: ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
                      children: [
                        _buildHeroCard(
                          p,
                          learnersCount: learnersCount,
                          avgPct: avgPct,
                          selectedMonthLabel: _month == null
                              ? 'All months'
                              : _monthLabel(_monthKey(_month!)),
                        ),
                        const SizedBox(height: 14),
                        _buildQuickStatsRow(
                          p,
                          avgPct: avgPct,
                          excellentCount: excellentCount,
                          atRiskCount: atRiskCount,
                        ),
                        const SizedBox(height: 14),
                        _buildFilterBar(p),
                        const SizedBox(height: 14),
                        ...rows.asMap().entries.map(
                          (entry) =>
                              _buildStatsCard(p, entry.key + 1, entry.value),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeroCard(
    AppPalette p, {
    required int learnersCount,
    required int avgPct,
    required String selectedMonthLabel,
  }) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [p.primary, p.primary.withValues(alpha: 0.88)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: p.primary.withValues(alpha: 0.16),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(18),
            ),
            child: const Icon(
              Icons.fact_check_rounded,
              color: Colors.white,
              size: 28,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  selectedMonthLabel,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.82),
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '$avgPct% class average',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    fontSize: 22,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '$learnersCount learner${learnersCount == 1 ? '' : 's'} included in this overview.',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.86),
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickStatsRow(
    AppPalette p, {
    required int avgPct,
    required int excellentCount,
    required int atRiskCount,
  }) {
    return Row(
      children: [
        Expanded(
          child: _miniStatCard(
            p,
            label: 'Average',
            value: '$avgPct%',
            icon: Icons.insights_rounded,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _miniStatCard(
            p,
            label: 'Strong',
            value: '$excellentCount',
            icon: Icons.emoji_events_rounded,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _miniStatCard(
            p,
            label: 'At Risk',
            value: '$atRiskCount',
            icon: Icons.warning_amber_rounded,
          ),
        ),
      ],
    );
  }

  Widget _miniStatCard(
    AppPalette p, {
    required String label,
    required String value,
    required IconData icon,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
      decoration: BoxDecoration(
        color: p.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: p.border.withValues(alpha: 0.8)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(color: p.soft, shape: BoxShape.circle),
            child: Icon(icon, color: p.primary, size: 19),
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(
              color: p.primary,
              fontWeight: FontWeight.w900,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              color: p.text.withValues(alpha: 0.65),
              fontWeight: FontWeight.w800,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterBar(AppPalette p) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: p.cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: p.border.withValues(alpha: 0.85)),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: p.soft,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(Icons.filter_alt_rounded, color: p.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Period',
                  style: TextStyle(
                    color: p.text.withValues(alpha: 0.65),
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.0,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  _month == null
                      ? 'All months'
                      : _monthLabel(_monthKey(_month!)),
                  style: TextStyle(
                    color: p.primary,
                    fontWeight: FontWeight.w900,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
          InkWell(
            onTap: _pickMonth,
            borderRadius: BorderRadius.circular(999),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: p.primary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: p.primary.withValues(alpha: 0.12)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.calendar_today_rounded,
                    size: 15,
                    color: p.primary,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Change',
                    style: TextStyle(
                      color: p.primary,
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatsCard(AppPalette p, int rank, Map<String, dynamic> row) {
    final pct = row['pct'] as int;
    final color = _getHealthColor(pct);
    final healthLabel = _healthLabel(pct);
    final healthIcon = _healthIcon(pct);

    final name = row['name'].toString().trim().isEmpty
        ? 'Learner'
        : row['name'].toString();
    final serial = row['serial'].toString().trim();
    final present = row['present'] as int;
    final absent = row['absent'] as int;
    final total = row['total'] as int;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: p.cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: p.border.withValues(alpha: 0.85)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: p.soft,
                  borderRadius: BorderRadius.circular(15),
                ),
                child: Center(
                  child: Text(
                    '#$rank',
                    style: TextStyle(
                      color: p.primary,
                      fontWeight: FontWeight.w900,
                      fontSize: 14,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 15,
                        color: p.primary,
                      ),
                    ),
                    if (serial.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        'ID: $serial',
                        style: TextStyle(
                          color: p.text.withValues(alpha: 0.65),
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '$pct%',
                    style: TextStyle(
                      color: color,
                      fontWeight: FontWeight.w900,
                      fontSize: 20,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: color.withValues(alpha: 0.18)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(healthIcon, size: 14, color: color),
                        const SizedBox(width: 6),
                        Text(
                          healthLabel,
                          style: TextStyle(
                            color: color,
                            fontWeight: FontWeight.w800,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: pct / 100,
              minHeight: 10,
              backgroundColor: color.withValues(alpha: 0.12),
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _statPill(
                color: successGreen,
                icon: Icons.check_circle_outline_rounded,
                text: '$present present',
              ),
              _statPill(
                color: dangerRed,
                icon: Icons.highlight_off_rounded,
                text: '$absent absent',
              ),
              _statPill(
                color: Colors.blueGrey,
                icon: Icons.event_note_rounded,
                text: '$total total',
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _statPill({
    required Color color,
    required IconData icon,
    required String text,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w800,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(AppPalette p) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: p.cardBg,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: p.border.withValues(alpha: 0.9)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.analytics_outlined,
                size: 58,
                color: p.primary.withValues(alpha: 0.22),
              ),
              const SizedBox(height: 14),
              Text(
                _month == null
                    ? 'No attendance data yet'
                    : 'No data for ${_monthLabel(_monthKey(_month!))}',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: p.primary,
                  fontWeight: FontWeight.w900,
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Try another month or save attendance first.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: p.text.withValues(alpha: 0.7),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildErrorState(AppPalette p) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: p.cardBg,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: dangerRed.withValues(alpha: 0.20)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.error_outline_rounded,
                size: 56,
                color: dangerRed,
              ),
              const SizedBox(height: 12),
              const Text(
                'Something went wrong',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: dangerRed,
                  fontSize: 15,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _error ?? 'Unknown error',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: p.text,
                  fontWeight: FontWeight.w700,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
