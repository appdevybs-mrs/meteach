import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import '../shared/admin_web_layout.dart';
import '../shared/human_error.dart';

class AdminTeacherSessionCountScreen extends StatefulWidget {
  const AdminTeacherSessionCountScreen({super.key});

  @override
  State<AdminTeacherSessionCountScreen> createState() =>
      _AdminTeacherSessionCountScreenState();
}

class _AdminTeacherSessionCountScreenState
    extends State<AdminTeacherSessionCountScreen> {
  static const primaryBlue = Color(0xFF1A2B48);
  static const appBg = Color(0xFFF4F7F9);
  static const uiBorder = Color(0xFFD1D9E0);
  static const accentGreen = Color(0xFF2B9E6A);

  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  bool _loading = true;
  String? _error;

  String _dateFilter = 'all';
  DateTime? _customFrom;
  DateTime? _customTo;

  final List<_TeacherStats> _teachers = [];
  int _totalSessions = 0;
  final Map<String, String> _courseTitles = {};
  final Set<String> _expandedTeachers = {};
  final Map<String, Set<String>> _expandedLearners = {};
  String? _printingTeacherId;
  bool _printingAll = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  String _two(int n) => n.toString().padLeft(2, '0');

  DateTime? _parseDate(String s) {
    final parts = s.split('-');
    if (parts.length != 3) return null;
    final y = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    final d = int.tryParse(parts[2]);
    if (y == null || m == null || d == null) return null;
    return DateTime(y, m, d);
  }

  bool _dateInRange(String dateStr) {
    final dt = _parseDate(dateStr);
    if (dt == null) return false;

    switch (_dateFilter) {
      case 'thisMonth':
        final now = DateTime.now();
        return dt.year == now.year && dt.month == now.month;
      case 'lastMonth':
        final now = DateTime.now();
        final lm = DateTime(now.year, now.month - 1, 1);
        return dt.year == lm.year && dt.month == lm.month;
      case 'custom':
        if (_customFrom != null && dt.isBefore(_customFrom!)) return false;
        final end = _customTo != null
            ? DateTime(_customTo!.year, _customTo!.month, _customTo!.day, 23, 59, 59)
            : null;
        if (end != null && dt.isAfter(end)) return false;
        return true;
      default:
        return true;
    }
  }

  int _toInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString()) ?? 0;
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _teachers.clear();
      _totalSessions = 0;
      _courseTitles.clear();
      _expandedTeachers.clear();
      _expandedLearners.clear();
    });

    try {
      final snap = await _db.child('booking_reservations').get();

      if (!snap.exists || snap.value is! Map) {
        setState(() => _loading = false);
        return;
      }

      final byCourse = Map<dynamic, dynamic>.from(snap.value as Map);
      final Map<String, _TeacherStats> teacherMap = {};
      final Set<String> neededCourseIds = {};

      for (final courseEntry in byCourse.entries) {
        final courseId = courseEntry.key.toString();
        final courseNode = courseEntry.value;
        if (courseNode is! Map) continue;

        final byDate = Map<dynamic, dynamic>.from(courseNode);

        for (final dateEntry in byDate.entries) {
          final dayKey = dateEntry.key.toString();
          final dateNode = dateEntry.value;
          if (dateNode is! Map) continue;

          if (!_dateInRange(dayKey)) continue;

          final byTime = Map<dynamic, dynamic>.from(dateNode);

          for (final timeEntry in byTime.entries) {
            final hhmm = timeEntry.key.toString();
            final slotVal = timeEntry.value;
            if (slotVal is! Map) continue;

            final m = Map<dynamic, dynamic>.from(slotVal);

            void collect(Map<dynamic, dynamic> slotNode, String implicitKey) {
              final teacherId =
                  (slotNode['teacherId'] ?? implicitKey).toString().trim();
              final teacherName =
                  (slotNode['teacherName'] ?? '').toString().trim();
              if (teacherId.isEmpty && teacherName.isEmpty) return;

              final key = teacherId.isNotEmpty ? teacherId : teacherName;

              teacherMap.putIfAbsent(
                key,
                () => _TeacherStats(teacherId: teacherId, teacherName: teacherName),
              );

              final learnersRaw = slotNode['learners'];
              final learnerCount = (learnersRaw is Map) ? learnersRaw.length : 0;
              final learnerNames = <String>[];
              if (learnersRaw is Map) {
                for (final lEntry in learnersRaw.entries) {
                  final lId = lEntry.key.toString();
                  final lName = lEntry.value.toString();
                  learnerNames.add(lName);

                  final teacher = teacherMap[key]!;
                  teacher.learners.putIfAbsent(
                    lId,
                    () => _LearnerStats(learnerId: lId, learnerName: lName),
                  );
                  teacher.learners[lId]!.sessions.add(_LearnerSessionInfo(
                    learnerId: lId,
                    learnerName: lName,
                    sessionNo: _toInt(slotNode['sessionNo']),
                    dateStr: dayKey,
                    timeStr: hhmm,
                    courseId: courseId,
                  ));
                  teacher.learners[lId]!.sessionCount++;
                }
              }

              teacherMap[key]!.sessions.add(_SessionDetail(
                courseId: courseId,
                dateStr: dayKey,
                timeStr: hhmm,
                sessionNo: _toInt(slotNode['sessionNo']),
                learnerCount: learnerCount,
                learnerNames: learnerNames,
              ));
              teacherMap[key]!.sessionCount++;
              _totalSessions++;
              neededCourseIds.add(courseId);
            }

            if (m['learners'] is Map) {
              collect(m, '');
              continue;
            }

            for (final teacherEntry in m.entries) {
              final teacherNode = teacherEntry.value;
              if (teacherNode is! Map) continue;
              collect(
                Map<dynamic, dynamic>.from(teacherNode),
                teacherEntry.key.toString(),
              );
            }
          }
        }
      }

      // Fetch course titles
      for (final cid in neededCourseIds) {
        try {
          final cSnap = await _db.child('courses/$cid/title').get();
          if (cSnap.exists && cSnap.value != null) {
            _courseTitles[cid] = cSnap.value.toString();
          } else {
            final cSnap2 = await _db.child('courses/$cid/name').get();
            if (cSnap2.exists && cSnap2.value != null) {
              _courseTitles[cid] = cSnap2.value.toString();
            } else {
              _courseTitles[cid] = cid;
            }
          }
        } catch (_) {
          _courseTitles[cid] = cid;
        }
      }

      // Apply course titles to sessions
      for (final teacher in teacherMap.values) {
        for (final session in teacher.sessions) {
          session.courseTitle = _courseTitles[session.courseId] ?? session.courseId;
        }
        for (final learner in teacher.learners.values) {
          for (final s in learner.sessions) {
            s.courseTitle = _courseTitles[s.courseId] ?? s.courseId;
          }
        }
      }

      final sorted = teacherMap.values.toList()
        ..sort((a, b) => b.sessionCount.compareTo(a.sessionCount));

      setState(() {
        _teachers.addAll(sorted);
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = toHumanError(e, fallback: 'Could not load session data.');
        _loading = false;
      });
    }
  }

  void _showFilterPicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (_) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Filter by Period',
                  style: TextStyle(
                    color: primaryBlue,
                    fontWeight: FontWeight.w900,
                    fontSize: 18,
                  ),
                ),
                const SizedBox(height: 16),
                _filterOption('All Time', 'all'),
                _filterOption('This Month', 'thisMonth'),
                _filterOption('Last Month', 'lastMonth'),
                _filterOption('Custom Range', 'custom', isCustom: true),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _filterOption(String label, String value, {bool isCustom = false}) {
    final selected = _dateFilter == value;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: isCustom
            ? () {
                Navigator.pop(context);
                _pickDateRange();
              }
            : () {
                Navigator.pop(context);
                setState(() => _dateFilter = value);
                _load();
              },
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: selected ? primaryBlue.withValues(alpha: 0.06) : Colors.white,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: selected ? primaryBlue : uiBorder.withValues(alpha: 0.85),
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: primaryBlue.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  isCustom ? Icons.date_range_rounded : Icons.calendar_month_rounded,
                  color: primaryBlue,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    color: primaryBlue,
                    fontWeight: FontWeight.w900,
                    fontSize: 14,
                  ),
                ),
              ),
              if (selected)
                Icon(Icons.check_circle_rounded, color: accentGreen),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickDateRange() async {
    final from = await showDatePicker(
      context: context,
      initialDate: _customFrom ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
      helpText: 'From date',
    );
    if (from == null || !mounted) return;

    final to = await showDatePicker(
      context: context,
      initialDate: _customTo ?? DateTime.now(),
      firstDate: from,
      lastDate: DateTime.now(),
      helpText: 'To date',
    );
    if (to == null || !mounted) return;

    setState(() {
      _customFrom = from;
      _customTo = to;
      _dateFilter = 'custom';
    });
    _load();
  }

  String _dateFilterLabel() {
    switch (_dateFilter) {
      case 'thisMonth':
        return 'This Month';
      case 'lastMonth':
        return 'Last Month';
      case 'custom':
        final from = _customFrom != null
            ? '${_customFrom!.year}-${_two(_customFrom!.month)}-${_two(_customFrom!.day)}'
            : '?';
        final to = _customTo != null
            ? '${_customTo!.year}-${_two(_customTo!.month)}-${_two(_customTo!.day)}'
            : '?';
        return '$from ~ $to';
      default:
        return 'All Time';
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
        title: const Text(
          'Teacher Session Count',
          style: TextStyle(color: primaryBlue, fontWeight: FontWeight.w900),
        ),
        actions: [
          if (_teachers.isNotEmpty)
            IconButton(
              tooltip: 'Print all teachers',
              icon: _printingAll
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.print_rounded, color: primaryBlue),
              onPressed: (_loading || _printingAll) ? null : _printAllTeachers,
            ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded, color: primaryBlue),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: adminWebBodyFrame(
        context: context,
        maxWidth: 1360,
        child: Stack(
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: Opacity(
                  opacity: 0.04,
                  child: Center(
                    child: Icon(
                      Icons.analytics_rounded,
                      size: 220,
                      color: primaryBlue.withValues(alpha: 0.12),
                    ),
                  ),
                ),
              ),
            ),
            SafeArea(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                      ? _buildError()
                      : _teachers.isEmpty
                          ? _buildEmpty()
                          : RefreshIndicator(
                              onRefresh: _load,
                              child: ListView(
                                physics: const AlwaysScrollableScrollPhysics(),
                                padding:
                                    const EdgeInsets.fromLTRB(16, 14, 16, 24),
                                children: [
                                  _buildHeroCard(),
                                  const SizedBox(height: 14),
                                  _buildQuickStats(),
                                  const SizedBox(height: 14),
                                  _buildFilterBar(),
                                  const SizedBox(height: 14),
                                  ..._teachers.asMap().entries.map(
                                    (entry) => _buildTeacherCard(
                                        entry.key + 1, entry.value),
                                  ),
                                ],
                              ),
                            ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeroCard() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [primaryBlue, primaryBlue.withValues(alpha: 0.88)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: primaryBlue.withValues(alpha: 0.16),
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
            child: const Icon(Icons.school_rounded, color: Colors.white, size: 28),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _dateFilterLabel(),
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.82),
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '$_totalSessions sessions taught',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    fontSize: 22,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '${_teachers.length} teacher${_teachers.length == 1 ? '' : 's'} with online bookings.',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.86),
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickStats() {
    final avg = _teachers.isEmpty
        ? 0
        : (_totalSessions / _teachers.length).round();
    final top = _teachers.isNotEmpty ? _teachers.first.sessionCount : 0;

    return Row(
      children: [
        Expanded(
          child: _miniStatCard(
            label: 'Teachers',
            value: '${_teachers.length}',
            icon: Icons.people_rounded,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _miniStatCard(
            label: 'Avg per teacher',
            value: '$avg',
            icon: Icons.insights_rounded,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _miniStatCard(
            label: 'Top teacher',
            value: '$top',
            icon: Icons.emoji_events_rounded,
          ),
        ),
      ],
    );
  }

  Widget _miniStatCard({
    required String label,
    required String value,
    required IconData icon,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: uiBorder.withValues(alpha: 0.8)),
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
            decoration: const BoxDecoration(
              color: Color(0xFFEEF2F6),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: primaryBlue, size: 19),
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: const TextStyle(
              color: primaryBlue,
              fontWeight: FontWeight.w900,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              color: Colors.black.withValues(alpha: 0.65),
              fontWeight: FontWeight.w800,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterBar() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: uiBorder.withValues(alpha: 0.85)),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: const Color(0xFFEEF2F6),
              borderRadius: BorderRadius.circular(14),
            ),
            child:
                const Icon(Icons.filter_alt_rounded, color: primaryBlue),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Period',
                  style: TextStyle(
                    color: Colors.black.withValues(alpha: 0.65),
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.0,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  _dateFilterLabel(),
                  style: const TextStyle(
                    color: primaryBlue,
                    fontWeight: FontWeight.w900,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
          InkWell(
            onTap: _showFilterPicker,
            borderRadius: BorderRadius.circular(999),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: primaryBlue.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                    color: primaryBlue.withValues(alpha: 0.12)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.calendar_today_rounded,
                      size: 15, color: primaryBlue),
                  const SizedBox(width: 6),
                  const Text(
                    'Change',
                    style: TextStyle(
                      color: primaryBlue,
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

  Widget _buildTeacherCard(int rank, _TeacherStats teacher) {
    final courseCount = teacher.sessions.map((s) => s.courseId).toSet().length;
    final isExpanded = _expandedTeachers.contains(teacher.teacherId);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: uiBorder.withValues(alpha: 0.85)),
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
          InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () {
              setState(() {
                if (isExpanded) {
                  _expandedTeachers.remove(teacher.teacherId);
                  _expandedLearners.remove(teacher.teacherId);
                } else {
                  _expandedTeachers.add(teacher.teacherId);
                }
              });
            },
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: const Color(0xFFEEF2F6),
                      borderRadius: BorderRadius.circular(15),
                    ),
                    child: Center(
                      child: Text(
                        '#$rank',
                        style: const TextStyle(
                          color: primaryBlue,
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
                          teacher.teacherName.isNotEmpty
                              ? teacher.teacherName
                              : '(No name)',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 15,
                            color: primaryBlue,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '${teacher.sessionCount} session${teacher.sessionCount == 1 ? '' : 's'} \u2022 $courseCount course${courseCount == 1 ? '' : 's'}',
                          style: TextStyle(
                            color: Colors.black.withValues(alpha: 0.65),
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  // Print per-teacher icon
                  _printingTeacherId == teacher.teacherId
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : IconButton(
                          tooltip: 'Print ${teacher.teacherName} sessions',
                          icon: const Icon(Icons.print_rounded,
                              color: primaryBlue, size: 20),
                          onPressed: () => _printTeacherSessions(teacher),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                  const SizedBox(width: 6),
                  AnimatedRotation(
                    turns: isExpanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(
                      Icons.keyboard_arrow_down_rounded,
                      color: Colors.black.withValues(alpha: 0.4),
                      size: 24,
                    ),
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            firstChild: const SizedBox.shrink(),
            secondChild: _buildLearnerList(teacher),
            crossFadeState: isExpanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 200),
          ),
        ],
      ),
    );
  }

  Widget _buildLearnerList(_TeacherStats teacher) {
    final sorted = teacher.learners.values.toList()
      ..sort((a, b) => b.sessionCount.compareTo(a.sessionCount));

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFF8F9FB),
        borderRadius: const BorderRadius.vertical(
            bottom: Radius.circular(20)),
        border: Border(
          top: BorderSide(color: uiBorder.withValues(alpha: 0.6)),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Learners (${sorted.length})',
            style: TextStyle(
              color: Colors.black.withValues(alpha: 0.5),
              fontWeight: FontWeight.w800,
              fontSize: 11,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 8),
          ...sorted.map((learner) => _buildLearnerRow(teacher, learner)),
        ],
      ),
    );
  }

  Widget _buildLearnerRow(_TeacherStats teacher, _LearnerStats learner) {
    final expandedSet = _expandedLearners.putIfAbsent(teacher.teacherId, () => {});
    final isExpanded = expandedSet.contains(learner.learnerId);

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: uiBorder.withValues(alpha: 0.6)),
      ),
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () {
              setState(() {
                if (isExpanded) {
                  expandedSet.remove(learner.learnerId);
                } else {
                  expandedSet.add(learner.learnerId);
                }
              });
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: primaryBlue.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.person_rounded,
                        size: 16, color: primaryBlue),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      learner.learnerName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                        color: primaryBlue,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: accentGreen.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '${learner.sessionCount}',
                      style: const TextStyle(
                        color: accentGreen,
                        fontWeight: FontWeight.w900,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  AnimatedRotation(
                    turns: isExpanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(
                      Icons.keyboard_arrow_down_rounded,
                      color: Colors.black.withValues(alpha: 0.3),
                      size: 20,
                    ),
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            firstChild: const SizedBox.shrink(),
            secondChild: _buildSessionDetails(learner),
            crossFadeState: isExpanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 200),
          ),
        ],
      ),
    );
  }

  Widget _buildSessionDetails(_LearnerStats learner) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Divider(color: uiBorder.withValues(alpha: 0.5), height: 1),
          const SizedBox(height: 8),
          ...learner.sessions.asMap().entries.map(
            (entry) {
              final i = entry.key + 1;
              final s = entry.value;
              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: primaryBlue.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Center(
                        child: Text(
                          '$i',
                          style: const TextStyle(
                            color: primaryBlue,
                            fontWeight: FontWeight.w800,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${s.dateStr} ${s.timeStr} — ${s.courseTitle}',
                        style: TextStyle(
                          color: Colors.black.withValues(alpha: 0.75),
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                          height: 1.3,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  // ──────────────────────────────────────────────
  // PDF / Print Methods
  // ──────────────────────────────────────────────

  Future<void> _printTeacherSessions(_TeacherStats teacher) async {
    setState(() => _printingTeacherId = teacher.teacherId);
    try {
      final bytes = await _buildTeacherPdf(teacher);
      await Printing.layoutPdf(
        name:
            '${teacher.teacherName.replaceAll(' ', '_')}_sessions.pdf',
        onLayout: (_) async => bytes,
      );
    } catch (_) {
      // silently fail
    } finally {
      if (mounted) setState(() => _printingTeacherId = null);
    }
  }

  Future<void> _printAllTeachers() async {
    setState(() => _printingAll = true);
    try {
      final bytes = await _buildAllTeachersPdf();
      await Printing.layoutPdf(
        name: 'all_teachers_sessions.pdf',
        onLayout: (_) async => bytes,
      );
    } catch (_) {
      // silently fail
    } finally {
      if (mounted) setState(() => _printingAll = false);
    }
  }

  Future<Uint8List> _buildTeacherPdf(_TeacherStats teacher) async {
    final doc = pw.Document();
    final sorted = teacher.sessions.toList()
      ..sort((a, b) {
        final c = a.dateStr.compareTo(b.dateStr);
        if (c != 0) return c;
        return a.timeStr.compareTo(b.timeStr);
      });

    final stamp =
        '${DateTime.now().year}-${_two(DateTime.now().month)}-${_two(DateTime.now().day)} '
        '${_two(DateTime.now().hour)}:${_two(DateTime.now().minute)}';

    doc.addPage(
      pw.MultiPage(
        pageTheme: pw.PageTheme(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.fromLTRB(28, 28, 28, 28),
        ),
        build: (ctx) => [
          pw.Header(
            level: 0,
            child: pw.Text(
              'Teacher Session Report',
              style: pw.TextStyle(
                fontSize: 22,
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.blue900,
              ),
            ),
          ),
          pw.SizedBox(height: 6),
          pw.Text(
            'Teacher: ${teacher.teacherName}',
            style: pw.TextStyle(
              fontSize: 16,
              fontWeight: pw.FontWeight.bold,
              color: PdfColors.blue800,
            ),
          ),
          pw.SizedBox(height: 4),
          pw.Text(
            'Total Sessions: ${teacher.sessionCount}',
            style: const pw.TextStyle(fontSize: 12),
          ),
          pw.Text(
            'Generated: $stamp',
            style: const pw.TextStyle(
                fontSize: 10, color: PdfColors.grey700),
          ),
          pw.SizedBox(height: 6),
          pw.Text(
            'Period: ${_dateFilterLabel()}',
            style: const pw.TextStyle(
                fontSize: 10, color: PdfColors.grey700),
          ),
          pw.SizedBox(height: 14),
          pw.Table(
            border: pw.TableBorder.all(
                color: PdfColors.black, width: 0.5),
            columnWidths: {
              0: const pw.FixedColumnWidth(28),
              1: const pw.FlexColumnWidth(1.4),
              2: const pw.FixedColumnWidth(70),
              3: const pw.FixedColumnWidth(60),
              4: const pw.FlexColumnWidth(1.8),
              5: const pw.FixedColumnWidth(60),
            },
            children: [
              pw.TableRow(
                decoration: const pw.BoxDecoration(
                    color: PdfColors.blue700),
                children: [
                  _pdfCell('#', isHeader: true, center: true),
                  _pdfCell('Date', isHeader: true, center: true),
                  _pdfCell('Time', isHeader: true, center: true),
                  _pdfCell('Session #', isHeader: true, center: true),
                  _pdfCell('Course', isHeader: true, center: true),
                  _pdfCell('Learners', isHeader: true, center: true),
                ],
              ),
              ...List.generate(sorted.length, (i) {
                final s = sorted[i];
                return pw.TableRow(
                  decoration: pw.BoxDecoration(
                    color:
                        i.isOdd ? PdfColors.grey50 : PdfColors.white,
                  ),
                  children: [
                    _pdfCell('${i + 1}', center: true),
                    _pdfCell(s.dateStr, center: true),
                    _pdfCell(s.timeStr, center: true),
                    _pdfCell('${s.sessionNo}', center: true),
                    _pdfCell(s.courseTitle),
                    _pdfCell(
                        '${s.learnerCount} ${s.learnerCount == 1 ? 'learner' : 'learners'}'),
                  ],
                );
              }),
            ],
          ),
        ],
      ),
    );

    return doc.save();
  }

  Future<Uint8List> _buildAllTeachersPdf() async {
    final doc = pw.Document();

    final stamp =
        '${DateTime.now().year}-${_two(DateTime.now().month)}-${_two(DateTime.now().day)} '
        '${_two(DateTime.now().hour)}:${_two(DateTime.now().minute)}';

    doc.addPage(
      pw.MultiPage(
        pageTheme: pw.PageTheme(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.fromLTRB(28, 28, 28, 28),
        ),
        build: (ctx) => [
          pw.Header(
            level: 0,
            child: pw.Text(
              'All Teachers — Session Report',
              style: pw.TextStyle(
                fontSize: 22,
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.blue900,
              ),
            ),
          ),
          pw.SizedBox(height: 4),
          pw.Text(
            'Total Teachers: ${_teachers.length}',
            style: const pw.TextStyle(fontSize: 12),
          ),
          pw.Text(
            'Total Sessions: $_totalSessions',
            style: const pw.TextStyle(fontSize: 12),
          ),
          pw.Text(
            'Generated: $stamp',
            style: const pw.TextStyle(
                fontSize: 10, color: PdfColors.grey700),
          ),
          pw.SizedBox(height: 4),
          pw.Text(
            'Period: ${_dateFilterLabel()}',
            style: const pw.TextStyle(
                fontSize: 10, color: PdfColors.grey700),
          ),
          pw.SizedBox(height: 16),
          // Build each teacher's table
          ..._teachers.expand((teacher) {
            final sorted = teacher.sessions.toList()
              ..sort((a, b) {
                final c = a.dateStr.compareTo(b.dateStr);
                if (c != 0) return c;
                return a.timeStr.compareTo(b.timeStr);
              });
            final courseCount =
                teacher.sessions.map((s) => s.courseId).toSet().length;

            return [
              pw.Header(
                level: 1,
                child: pw.Text(
                  '${teacher.teacherName} — ${teacher.sessionCount} sessions, $courseCount courses',
                  style: pw.TextStyle(
                    fontSize: 14,
                    fontWeight: pw.FontWeight.bold,
                    color: PdfColors.blue800,
                  ),
                ),
              ),
              pw.SizedBox(height: 6),
              pw.Table(
                border: pw.TableBorder.all(
                    color: PdfColors.black, width: 0.5),
                columnWidths: {
                  0: const pw.FixedColumnWidth(28),
                  1: const pw.FlexColumnWidth(1.4),
                  2: const pw.FixedColumnWidth(70),
                  3: const pw.FixedColumnWidth(60),
                  4: const pw.FlexColumnWidth(1.8),
                  5: const pw.FixedColumnWidth(60),
                },
                children: [
                  pw.TableRow(
                    decoration: const pw.BoxDecoration(
                        color: PdfColors.blue700),
                    children: [
                      _pdfCell('#', isHeader: true, center: true),
                      _pdfCell('Date', isHeader: true, center: true),
                      _pdfCell('Time', isHeader: true, center: true),
                      _pdfCell('Session #',
                          isHeader: true, center: true),
                      _pdfCell('Course', isHeader: true, center: true),
                      _pdfCell('Learners',
                          isHeader: true, center: true),
                    ],
                  ),
                  ...List.generate(sorted.length, (i) {
                    final s = sorted[i];
                    return pw.TableRow(
                      decoration: pw.BoxDecoration(
                        color: i.isOdd
                            ? PdfColors.grey50
                            : PdfColors.white,
                      ),
                      children: [
                        _pdfCell('${i + 1}', center: true),
                        _pdfCell(s.dateStr, center: true),
                        _pdfCell(s.timeStr, center: true),
                        _pdfCell('${s.sessionNo}', center: true),
                        _pdfCell(s.courseTitle),
                        _pdfCell(
                            '${s.learnerCount} ${s.learnerCount == 1 ? 'learner' : 'learners'}'),
                      ],
                    );
                  }),
                ],
              ),
              pw.SizedBox(height: 16),
            ];
          }),
        ],
      ),
    );

    return doc.save();
  }

  pw.Widget _pdfCell(
    String text, {
    bool isHeader = false,
    bool center = false,
  }) {
    return pw.Container(
      padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 5),
      child: pw.Text(
        text,
        textAlign: center ? pw.TextAlign.center : pw.TextAlign.left,
        style: pw.TextStyle(
          fontSize: isHeader ? 9 : 8,
          fontWeight:
              isHeader ? pw.FontWeight.bold : pw.FontWeight.normal,
          color: isHeader ? PdfColors.white : PdfColors.black,
        ),
      ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: uiBorder.withValues(alpha: 0.9)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.school_outlined,
                size: 58,
                color: primaryBlue.withValues(alpha: 0.22),
              ),
              const SizedBox(height: 14),
              const Text(
                'No session data found',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: primaryBlue,
                  fontWeight: FontWeight.w900,
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _dateFilter == 'all'
                    ? 'No online bookings have been made yet.'
                    : 'No sessions found for the selected period.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.black.withValues(alpha: 0.7),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: Colors.red.withValues(alpha: 0.20)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline_rounded,
                  size: 56, color: Colors.red),
              const SizedBox(height: 12),
              const Text(
                'Something went wrong',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.red,
                  fontSize: 15,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _error ?? 'Unknown error',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.black.withValues(alpha: 0.7),
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

// ---- Data Models ----

class _SessionDetail {
  final String courseId;
  String courseTitle = '';
  final String dateStr;
  final String timeStr;
  final int sessionNo;
  final int learnerCount;
  final List<String> learnerNames;

  _SessionDetail({
    required this.courseId,
    required this.dateStr,
    required this.timeStr,
    required this.sessionNo,
    required this.learnerCount,
    this.learnerNames = const [],
  });
}

class _LearnerSessionInfo {
  final String learnerId;
  final String learnerName;
  final int sessionNo;
  final String dateStr;
  final String timeStr;
  final String courseId;
  String courseTitle = '';

  _LearnerSessionInfo({
    required this.learnerId,
    required this.learnerName,
    required this.sessionNo,
    required this.dateStr,
    required this.timeStr,
    required this.courseId,
  });
}

class _LearnerStats {
  final String learnerId;
  final String learnerName;
  int sessionCount = 0;
  List<_LearnerSessionInfo> sessions = [];

  _LearnerStats({
    required this.learnerId,
    required this.learnerName,
  });
}

class _TeacherStats {
  final String teacherId;
  final String teacherName;
  int sessionCount = 0;
  List<_SessionDetail> sessions = [];
  Map<String, _LearnerStats> learners = {};

  _TeacherStats({
    required this.teacherId,
    required this.teacherName,
  });
}
