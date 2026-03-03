// ✅ FULL REPLACEMENT: lib/teacher/teacher_online_booking.dart
// OPTION 1 (Recommended): Day Editor UI (no grid tapping)
// Weekly repeating availability (Mon–Sun). Teachers create time blocks per day.
// Saves to: booking_availability/<teacherUid>/<courseId>

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

class TeacherOnlineBookingScreen extends StatefulWidget {
  const TeacherOnlineBookingScreen({super.key});

  @override
  State<TeacherOnlineBookingScreen> createState() => _TeacherOnlineBookingScreenState();
}

class _TeacherOnlineBookingScreenState extends State<TeacherOnlineBookingScreen> {
  // ===== Brand colors (match your style) =====
  static const primaryBlue = Color(0xFF1A2B48);
  static const actionOrange = Color(0xFFF98D28);
  static const appBg = Color(0xFFF4F7F9);
  static const uiBorder = Color(0xFFD1D9E0);
  static const mainText = Color(0xFF2D2D2D);

  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  // Teacher info
  String myUid = '';
  String myName = 'Teacher';

  // Courses (from users/<uid>/courses)
  bool loading = true;
  bool saving = false;
  List<_CoursePick> myCourses = [];
  String? selectedCourseId;

  // Time range (visual guideline only)
  int startHour = 8; // 08:00
  int endHour = 20; // 20:00
  int stepMinutes = 30;

  // Weekly data
  final List<String> dayKeys = const ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
  final List<String> dayLabels = const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  // Map dayKey -> list of blocks
  final Map<String, List<_TimeBlock>> week = {
    'mon': [],
    'tue': [],
    'wed': [],
    'thu': [],
    'fri': [],
    'sat': [],
    'sun': [],
  };

  @override
  void initState() {
    super.initState();
    _init();
  }

  // ===================== Helpers =====================

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  DatabaseReference _availRef(String courseId) => _db.child('booking_availability/$myUid/$courseId');

  String _two(int n) => n < 10 ? '0$n' : '$n';

  String _fmt(TimeOfDay t) => '${_two(t.hour)}:${_two(t.minute)}';

  int _toInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  int _tToMinutes(TimeOfDay t) => t.hour * 60 + t.minute;

  TimeOfDay _minutesToTime(int m) {
    final hh = (m ~/ 60) % 24;
    final mm = m % 60;
    return TimeOfDay(hour: hh, minute: mm);
  }

  // Suggest next start time for a day
  TimeOfDay _suggestStart(String dayKey) {
    final blocks = week[dayKey] ?? [];
    if (blocks.isEmpty) return TimeOfDay(hour: startHour, minute: 0);

    final sorted = [...blocks]..sort((a, b) => _tToMinutes(a.start).compareTo(_tToMinutes(b.start)));
    final last = sorted.last;
    final nextM = _tToMinutes(last.end);
    return _minutesToTime(nextM.clamp(startHour * 60, endHour * 60));
  }

  // Normalize: sort + merge overlaps + clamp
  void _normalizeDay(String dayKey) {
    final blocks = week[dayKey] ?? [];
    if (blocks.isEmpty) return;

    // clamp + remove invalid
    final filtered = <_TimeBlock>[];
    for (final b in blocks) {
      var s = _tToMinutes(b.start);
      var e = _tToMinutes(b.end);

      final minM = startHour * 60;
      final maxM = endHour * 60;

      if (s < minM) s = minM;
      if (e > maxM) e = maxM;

      if (e <= s) continue;

      filtered.add(_TimeBlock(start: _minutesToTime(s), end: _minutesToTime(e)));
    }

    filtered.sort((a, b) => _tToMinutes(a.start).compareTo(_tToMinutes(b.start)));

    // merge overlaps
    final merged = <_TimeBlock>[];
    for (final b in filtered) {
      if (merged.isEmpty) {
        merged.add(b);
        continue;
      }

      final last = merged.last;
      final lastEnd = _tToMinutes(last.end);
      final curStart = _tToMinutes(b.start);
      final curEnd = _tToMinutes(b.end);

      if (curStart < lastEnd) {
        // overlap/touch -> extend end
        final newEnd = _minutesToTime(curEnd > lastEnd ? curEnd : lastEnd);
        merged[merged.length - 1] = _TimeBlock(start: last.start, end: newEnd);
      } else {
        merged.add(b);
      }
    }

    week[dayKey] = merged;
  }

  // ===================== Init / Load =====================

  Future<void> _init() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      setState(() => loading = false);
      _toast('Not logged in.');
      return;
    }

    myUid = uid;
    await _loadMyName();
    await _loadMyCourses();

    final cid = selectedCourseId;
    if (cid != null) {
      await _loadAvailability(cid);
    }

    if (!mounted) return;
    setState(() => loading = false);
  }

  Future<void> _loadMyName() async {
    try {
      final snap = await _db.child('users/$myUid').get();
      final v = snap.value;
      if (v is Map) {
        final m = v.map((k, vv) => MapEntry(k.toString(), vv));
        final first = (m['first_name'] ?? '').toString().trim();
        final last = (m['last_name'] ?? '').toString().trim();
        final full = ('$first $last').trim();
        if (full.isNotEmpty) myName = full;
      }
    } catch (_) {}
  }

  Future<void> _loadMyCourses() async {
    try {
      final snap = await _db.child('users/$myUid/courses').get();
      final v = snap.value;

      final out = <_CoursePick>[];

      if (v is Map) {
        final raw = Map<dynamic, dynamic>.from(v);
        for (final entry in raw.entries) {
          final val = entry.value;
          if (val is! Map) continue;
          final m = val.map((k, vv) => MapEntry(k.toString(), vv));

          final id = (m['id'] ?? '').toString().trim();
          if (id.isEmpty) continue;

          final title = (m['title'] ?? '').toString().trim();
          final code = (m['course_code'] ?? '').toString().trim();

          out.add(_CoursePick(
            id: id,
            title: title.isEmpty ? 'Untitled' : title,
            code: code,
          ));
        }
      }

      out.sort((a, b) => a.title.compareTo(b.title));

      setState(() {
        myCourses = out;
        selectedCourseId = out.isNotEmpty ? out.first.id : null;
      });

      if (out.isEmpty) _toast('No courses assigned to you (users/$myUid/courses).');
    } catch (e) {
      _toast('Failed loading courses: $e');
    }
  }

  Future<void> _loadAvailability(String courseId) async {
    // clear local week
    for (final dk in dayKeys) {
      week[dk] = [];
    }

    try {
      final snap = await _availRef(courseId).get();
      if (!snap.exists || snap.value == null) {
        setState(() {});
        return;
      }

      final v = snap.value;
      if (v is! Map) {
        setState(() {});
        return;
      }

      final m = v.map((k, vv) => MapEntry(k.toString(), vv));

      final sh = _toInt(m['startHour']);
      final eh = _toInt(m['endHour']);
      final sm = _toInt(m['stepMinutes']);

      if (sh > 0 && eh > sh && sm > 0) {
        startHour = sh;
        endHour = eh;
        stepMinutes = sm;
      }

      final weekNode = m['week'];
      if (weekNode is Map) {
        final wm = weekNode.map((k, vv) => MapEntry(k.toString(), vv));
        for (final dk in dayKeys) {
          final list = wm[dk];
          final blocks = <_TimeBlock>[];

          if (list is List) {
            for (final item in list) {
              if (item is! Map) continue;
              final im = item.map((k, vv) => MapEntry(k.toString(), vv));
              final s = (im['start'] ?? '').toString().trim();
              final e = (im['end'] ?? '').toString().trim();
              final st = _parseHHMM(s);
              final en = _parseHHMM(e);
              if (st == null || en == null) continue;
              blocks.add(_TimeBlock(start: st, end: en));
            }
          }

          week[dk] = blocks;
          _normalizeDay(dk);
        }
      }

      setState(() {});
    } catch (e) {
      _toast('Failed loading availability: $e');
      setState(() {});
    }
  }

  TimeOfDay? _parseHHMM(String s) {
    final parts = s.split(':');
    if (parts.length != 2) return null;
    final hh = int.tryParse(parts[0]);
    final mm = int.tryParse(parts[1]);
    if (hh == null || mm == null) return null;
    if (hh < 0 || hh > 23) return null;
    if (mm < 0 || mm > 59) return null;
    return TimeOfDay(hour: hh, minute: mm);
  }

  // ===================== Save =====================

  Future<void> _saveAvailability() async {
    final courseId = selectedCourseId;
    if (courseId == null || courseId.isEmpty) {
      _toast('Select a course first.');
      return;
    }

    // normalize all days before save
    for (final dk in dayKeys) {
      _normalizeDay(dk);
    }

    final payloadWeek = <String, dynamic>{};
    for (final dk in dayKeys) {
      final blocks = week[dk] ?? [];
      payloadWeek[dk] = blocks
          .map((b) => {
        'start': _fmt(b.start),
        'end': _fmt(b.end),
      })
          .toList();
    }

    setState(() => saving = true);
    try {
      await _availRef(courseId).set({
        'teacherId': myUid,
        'teacherName': myName,
        'startHour': startHour,
        'endHour': endHour,
        'stepMinutes': stepMinutes,
        'updatedAt': ServerValue.timestamp,
        'week': payloadWeek,
      });

      _toast('Availability saved ✅');
    } catch (e) {
      _toast('Save failed: $e');
    } finally {
      if (!mounted) return;
      setState(() => saving = false);
    }
  }

  // ===================== UI Actions =====================

  Future<void> _openDayEditor(String dayKey, String label) async {
    final blocks = [...(week[dayKey] ?? [])]; // local copy for editing

    void normalizeLocal() {
      blocks.sort((a, b) => _tToMinutes(a.start).compareTo(_tToMinutes(b.start)));
      final merged = <_TimeBlock>[];
      for (final b in blocks) {
        if (merged.isEmpty) {
          merged.add(b);
          continue;
        }
        final last = merged.last;
        final lastEnd = _tToMinutes(last.end);
        final curStart = _tToMinutes(b.start);
        final curEnd = _tToMinutes(b.end);
        if (curStart < lastEnd) {
          final newEnd = _minutesToTime(curEnd > lastEnd ? curEnd : lastEnd);
          merged[merged.length - 1] = _TimeBlock(start: last.start, end: newEnd);
        } else {
          merged.add(b);
        }
      }
      blocks
        ..clear()
        ..addAll(merged);
    }

    Future<TimeOfDay?> pickTime(TimeOfDay initial) async {
      return showTimePicker(
        context: context,
        initialTime: initial,
        helpText: 'Pick time',
        builder: (ctx, child) {
          return Theme(
            data: Theme.of(ctx).copyWith(
              colorScheme: Theme.of(ctx).colorScheme.copyWith(primary: actionOrange),
            ),
            child: child!,
          );
        },
      );
    }

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: appBg,
      showDragHandle: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModal) {
            final dayCount = blocks.length;

            return SafeArea(
              child: Padding(
                padding: EdgeInsets.only(
                  left: 14,
                  right: 14,
                  top: 8,
                  bottom: MediaQuery.of(ctx).viewInsets.bottom + 14,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // header
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: uiBorder.withOpacity(0.85)),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: primaryBlue.withOpacity(0.08),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: uiBorder.withOpacity(0.85)),
                            ),
                            child: const Icon(Icons.view_week_rounded, color: primaryBlue),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '$label availability',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w900,
                                    color: primaryBlue,
                                    fontSize: 16,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Add blocks like 14:00 → 16:00 (weekly repeating)',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    color: Colors.grey.shade600,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            decoration: BoxDecoration(
                              color: actionOrange.withOpacity(0.10),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(color: actionOrange.withOpacity(0.25)),
                            ),
                            child: Text(
                              '$dayCount block${dayCount == 1 ? '' : 's'}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w900,
                                color: actionOrange,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 12),

                    // quick add
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: primaryBlue,
                              side: BorderSide(color: uiBorder.withOpacity(0.9)),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                            onPressed: () {
                              final s = _suggestStart(dayKey);
                              final sMin = _tToMinutes(s);
                              final eMin = (sMin + 60).clamp(startHour * 60, endHour * 60);
                              final e = _minutesToTime(eMin);

                              setModal(() {
                                blocks.add(_TimeBlock(start: s, end: e));
                                normalizeLocal();
                              });
                            },
                            icon: const Icon(Icons.add_rounded),
                            label: const Text('Add block', style: TextStyle(fontWeight: FontWeight.w900)),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.red,
                              side: const BorderSide(color: Colors.red),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                            onPressed: blocks.isEmpty ? null : () => setModal(() => blocks.clear()),
                            icon: const Icon(Icons.delete_outline_rounded),
                            label: const Text('Clear day', style: TextStyle(fontWeight: FontWeight.w900)),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 12),

                    // list
                    ConstrainedBox(
                      constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.55),
                      child: blocks.isEmpty
                          ? Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(color: uiBorder.withOpacity(0.85)),
                        ),
                        child: const Text(
                          'No blocks yet.\nTap "Add block" to add your teaching hours.',
                          style: TextStyle(fontWeight: FontWeight.w800),
                        ),
                      )
                          : ListView.separated(
                        shrinkWrap: true,
                        itemCount: blocks.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (context, i) {
                          final b = blocks[i];

                          return Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(color: uiBorder.withOpacity(0.85)),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Container(
                                      width: 40,
                                      height: 40,
                                      decoration: BoxDecoration(
                                        color: actionOrange.withOpacity(0.10),
                                        borderRadius: BorderRadius.circular(14),
                                        border: Border.all(color: actionOrange.withOpacity(0.25)),
                                      ),
                                      child: const Icon(Icons.access_time_rounded, color: actionOrange),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        '${_fmt(b.start)}  →  ${_fmt(b.end)}',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w900,
                                          color: primaryBlue,
                                          fontSize: 15,
                                        ),
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: 'Remove',
                                      onPressed: () => setModal(() => blocks.removeAt(i)),
                                      icon: const Icon(Icons.close_rounded, color: Colors.red),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                Wrap(
                                  spacing: 10,
                                  runSpacing: 10,
                                  children: [
                                    OutlinedButton(
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: primaryBlue,
                                        side: BorderSide(color: uiBorder.withOpacity(0.9)),
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                                      ),
                                      onPressed: () async {
                                        final picked = await pickTime(b.start);
                                        if (picked == null) return;

                                        final ns = picked;
                                        var ne = b.end;

                                        if (_tToMinutes(ne) <= _tToMinutes(ns)) {
                                          ne = _minutesToTime(
                                            (_tToMinutes(ns) + stepMinutes).clamp(startHour * 60, endHour * 60),
                                          );
                                        }

                                        setModal(() {
                                          blocks[i] = _TimeBlock(start: ns, end: ne);
                                          normalizeLocal();
                                        });
                                      },
                                      child: Text(
                                        'Start: ${_fmt(b.start)}',
                                        style: const TextStyle(fontWeight: FontWeight.w900),
                                      ),
                                    ),
                                    OutlinedButton(
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: primaryBlue,
                                        side: BorderSide(color: uiBorder.withOpacity(0.9)),
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                                      ),
                                      onPressed: () async {
                                        final picked = await pickTime(b.end);
                                        if (picked == null) return;

                                        final ns = b.start;
                                        final ne = picked;

                                        if (_tToMinutes(ne) <= _tToMinutes(ns)) {
                                          _toast('End must be after start.');
                                          return;
                                        }

                                        setModal(() {
                                          blocks[i] = _TimeBlock(start: ns, end: ne);
                                          normalizeLocal();
                                        });
                                      },
                                      child: Text(
                                        'End: ${_fmt(b.end)}',
                                        style: const TextStyle(fontWeight: FontWeight.w900),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),

                    const SizedBox(height: 12),

                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            style: FilledButton.styleFrom(
                              backgroundColor: actionOrange,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                            ),
                            onPressed: () {
                              setState(() {
                                week[dayKey] = [...blocks];
                                _normalizeDay(dayKey);
                              });
                              Navigator.of(ctx).pop();
                            },
                            icon: const Icon(Icons.check_circle_rounded),
                            label: const Text('Done', style: TextStyle(fontWeight: FontWeight.w900)),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  // ===================== Build UI =====================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: primaryBlue),
        title: const Text(
          'Online Booking (Teacher)',
          style: TextStyle(color: primaryBlue, fontWeight: FontWeight.w900),
        ),
        actions: [
          IconButton(
            tooltip: 'Save',
            onPressed: saving ? null : _saveAvailability,
            icon: saving
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.save_rounded, color: actionOrange),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _CardBox(
            title: '1) Course',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _courseDropdown(),
                const SizedBox(height: 10),
                const _InfoBox(
                  text:
                  'This timetable repeats every week.\n'
                      'Tap a day to add time blocks (ex: 14:00 → 16:00).\n'
                      'Then press Save.',
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _CardBox(
            title: '2) Weekly Timetable',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _dayChips(),
                const SizedBox(height: 12),
                ...List.generate(7, (i) {
                  final dk = dayKeys[i];
                  final label = dayLabels[i];
                  return _DayCard(
                    label: label,
                    blocks: week[dk] ?? const [],
                    onTap: saving ? null : () => _openDayEditor(dk, label),
                    fmt: _fmt,
                  );
                }),
                const SizedBox(height: 12),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: actionOrange,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  onPressed: saving ? null : _saveAvailability,
                  icon: const Icon(Icons.check_circle_rounded),
                  label: Text(
                    saving ? 'Saving…' : 'Save weekly availability',
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _CardBox(
            title: 'Saved location',
            child: Text(
              'booking_availability/$myUid/<courseId>',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: mainText.withOpacity(0.75),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _courseDropdown() {
    if (myCourses.isEmpty) {
      return const _InfoBox(text: 'No courses assigned in users/<uid>/courses.');
    }

    final safeValue = myCourses.any((x) => x.id == selectedCourseId) ? selectedCourseId : myCourses.first.id;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: uiBorder),
      ),
      child: DropdownButton<String>(
        value: safeValue,
        isExpanded: true,
        underline: const SizedBox.shrink(),
        items: myCourses.map((c) {
          final label = c.code.isEmpty ? c.title : '${c.title}  —  ${c.code}';
          return DropdownMenuItem(
            value: c.id,
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          );
        }).toList(),
        onChanged: saving
            ? null
            : (v) async {
          if (v == null) return;
          setState(() {
            selectedCourseId = v;
          });
          await _loadAvailability(v);
          _toast('Loaded ✅');
        },
      ),
    );
  }

  Widget _dayChips() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: List.generate(7, (i) {
        final dk = dayKeys[i];
        final label = dayLabels[i];
        final count = (week[dk] ?? []).length;

        return InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: saving ? null : () => _openDayEditor(dk, label),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: uiBorder.withOpacity(0.85)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: const TextStyle(fontWeight: FontWeight.w900, color: primaryBlue),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: count == 0 ? appBg : actionOrange.withOpacity(0.10),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: (count == 0 ? uiBorder : actionOrange).withOpacity(0.35)),
                  ),
                  child: Text(
                    '$count',
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      color: count == 0 ? primaryBlue.withOpacity(0.6) : actionOrange,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      }),
    );
  }
}

// ===================== Models =====================

class _CoursePick {
  final String id;
  final String title;
  final String code;
  _CoursePick({required this.id, required this.title, required this.code});
}

class _TimeBlock {
  final TimeOfDay start;
  final TimeOfDay end;
  _TimeBlock({required this.start, required this.end});
}

// ===================== UI Components =====================

class _CardBox extends StatelessWidget {
  const _CardBox({required this.title, required this.child});

  final String title;
  final Widget child;

  static const primaryBlue = Color(0xFF1A2B48);
  static const uiBorder = Color(0xFFD1D9E0);

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: uiBorder),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w900, color: primaryBlue)),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

class _InfoBox extends StatelessWidget {
  const _InfoBox({required this.text});
  final String text;

  static const appBg = Color(0xFFF4F7F9);
  static const uiBorder = Color(0xFFD1D9E0);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: appBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: uiBorder),
      ),
      child: Text(text, style: const TextStyle(fontWeight: FontWeight.w700)),
    );
  }
}

class _DayCard extends StatelessWidget {
  const _DayCard({
    required this.label,
    required this.blocks,
    required this.onTap,
    required this.fmt,
  });

  final String label;
  final List<_TimeBlock> blocks;
  final VoidCallback? onTap;
  final String Function(TimeOfDay) fmt;

  static const primaryBlue = Color(0xFF1A2B48);
  static const actionOrange = Color(0xFFF98D28);
  static const uiBorder = Color(0xFFD1D9E0);

  @override
  Widget build(BuildContext context) {
    final has = blocks.isNotEmpty;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: uiBorder.withOpacity(0.85)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.03),
              blurRadius: 10,
              offset: const Offset(0, 6),
            )
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: has ? actionOrange.withOpacity(0.10) : primaryBlue.withOpacity(0.06),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: has ? actionOrange.withOpacity(0.25) : uiBorder.withOpacity(0.85),
                ),
              ),
              child: Icon(
                has ? Icons.check_circle_rounded : Icons.event_available_rounded,
                color: has ? actionOrange : primaryBlue,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      color: primaryBlue,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 6),
                  if (!has)
                    Text(
                      'No availability yet (tap to add)',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: Colors.grey.shade600,
                        fontSize: 12,
                      ),
                    )
                  else
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: blocks.map((b) {
                        return Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                          decoration: BoxDecoration(
                            color: actionOrange.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(color: actionOrange.withOpacity(0.22)),
                          ),
                          child: Text(
                            '${fmt(b.start)} → ${fmt(b.end)}',
                            style: const TextStyle(
                              fontWeight: FontWeight.w900,
                              color: actionOrange,
                              fontSize: 12,
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            const Icon(Icons.chevron_right_rounded, color: Colors.grey),
          ],
        ),
      ),
    );
  }
}