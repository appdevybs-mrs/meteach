// ✅ FULL REPLACEMENT (OPTION 1): lib/teacher/teacher_online_booking.dart
// New UX: 1-hour fixed slots (checkbox timetable). No blocks, no merging.
// Saves to: booking_availability/<teacherUid>/<courseId>
//
// Data format (new):
// booking_availability/<teacherUid>/<courseId>/
//   startHour: 8
//   endHour: 21
//   slotMinutes: 60
//   week:
//     mon: ["08:00","09:00","13:00"]
//
// Backward compatible loader:
// If it finds old blocks [{start,end}], it converts them into 1-hour slots.

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

class TeacherOnlineBookingScreen extends StatefulWidget {
  const TeacherOnlineBookingScreen({super.key});

  @override
  State<TeacherOnlineBookingScreen> createState() => _TeacherOnlineBookingScreenState();
}

class _TeacherOnlineBookingScreenState extends State<TeacherOnlineBookingScreen> {
  // ===== Brand colors =====
  static const primaryBlue = Color(0xFF1A2B48);
  static const actionOrange = Color(0xFFF98D28);
  static const appBg = Color(0xFFF4F7F9);
  static const uiBorder = Color(0xFFD1D9E0);
  static const mainText = Color(0xFF2D2D2D);

  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  // Teacher info
  String myUid = '';
  String myName = 'Teacher';

  // Courses
  bool loading = true;
  bool saving = false;
  List<_CoursePick> myCourses = [];
  String? selectedCourseId;

  // Timetable range
  int startHour = 8;  // inclusive
  int endHour = 21;   // exclusive (21 means last slot starts at 20:00)
  final int slotMinutes = 60;

  // Days
  final List<String> dayKeys = const ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
  final List<String> dayLabels = const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  // Map dayKey -> set of selected slot start minutes (e.g., 08:00 = 480)
  final Map<String, Set<int>> weekSlots = {
    'mon': <int>{},
    'tue': <int>{},
    'wed': <int>{},
    'thu': <int>{},
    'fri': <int>{},
    'sat': <int>{},
    'sun': <int>{},
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

  List<int> _hoursInRange(int fromHour, int toHour) {
    final a = fromHour.clamp(startHour, endHour);
    final b = toHour.clamp(startHour, endHour);
    if (b <= a) return [];
    return List.generate(b - a, (i) => a + i);
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
      weekSlots[dk] = <int>{};
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
      final sm = _toInt(m['slotMinutes']); // new field
      final oldSm = _toInt(m['stepMinutes']); // old field (ignore for new UI)

      // Only apply if sane. Prefer new "slotMinutes" but allow old data.
      if (sh > 0 && eh > sh) {
        startHour = sh;
        endHour = eh;
      }
      // slotMinutes fixed to 60 in UI; we only read to avoid crashing.
      // If somebody saved different slotMinutes, we still display as 60.

      final weekNode = m['week'];
      if (weekNode is Map) {
        final wm = weekNode.map((k, vv) => MapEntry(k.toString(), vv));

        for (final dk in dayKeys) {
          final list = wm[dk];
          final set = <int>{};

          // NEW FORMAT: list of "HH:MM"
          if (list is List && list.isNotEmpty && list.first is! Map) {
            for (final item in list) {
              final s = item.toString().trim();
              final t = _parseHHMM(s);
              if (t == null) continue;

              final minutes = _tToMinutes(t);
              // keep only slot starts inside range
              if (minutes >= startHour * 60 && minutes <= (endHour - 1) * 60) {
                // must align to full hour
                if (minutes % 60 == 0) set.add(minutes);
              }
            }
          }

          // OLD FORMAT: list of blocks [{start,end}]
          if (list is List && list.isNotEmpty && list.first is Map) {
            for (final item in list) {
              if (item is! Map) continue;
              final im = item.map((k, vv) => MapEntry(k.toString(), vv));
              final s = (im['start'] ?? '').toString().trim();
              final e = (im['end'] ?? '').toString().trim();
              final st = _parseHHMM(s);
              final en = _parseHHMM(e);
              if (st == null || en == null) continue;

              final sMin = _tToMinutes(st);
              final eMin = _tToMinutes(en);

              // Convert block into hour slots (start times)
              // Example 08:00-10:00 => 08:00, 09:00
              for (int cur = sMin; cur + 60 <= eMin; cur += 60) {
                if (cur >= startHour * 60 && cur <= (endHour - 1) * 60) {
                  if (cur % 60 == 0) set.add(cur);
                }
              }
            }
          }

          weekSlots[dk] = set;
        }
      }

      setState(() {});
    } catch (e) {
      _toast('Failed loading availability: $e');
      setState(() {});
    }
  }

  // ===================== Save =====================

  Future<void> _saveAvailability() async {
    final courseId = selectedCourseId;
    if (courseId == null || courseId.isEmpty) {
      _toast('Select a course first.');
      return;
    }

    final payloadWeek = <String, dynamic>{};

    for (final dk in dayKeys) {
      final slots = (weekSlots[dk] ?? <int>{}).toList()..sort();
      payloadWeek[dk] = slots.map((m) => _fmt(_minutesToTime(m))).toList();
    }

    setState(() => saving = true);
    try {
      await _availRef(courseId).set({
        'teacherId': myUid,
        'teacherName': myName,
        'startHour': startHour,
        'endHour': endHour,
        'slotMinutes': 60,
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

  // ===================== Day Editor (Checkbox Timetable) =====================

  Future<void> _openDayEditor(String dayKey, String label) async {
    final local = <int>{...(weekSlots[dayKey] ?? <int>{})};

    // Split into "Morning" and "Afternoon/Evening" like you asked
    // Morning: startHour .. 13
    // Afternoon: 13 .. endHour
    const splitHour = 13;

    final morningHours = _hoursInRange(startHour, splitHour);
    final afternoonHours = _hoursInRange(splitHour, endHour);

    Widget slotRow(String title, List<int> hours) {
      if (hours.isEmpty) return const SizedBox.shrink();

      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: uiBorder.withOpacity(0.85)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w900, color: primaryBlue)),
            const SizedBox(height: 10),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: hours.map((h) {
                  final startM = h * 60;
                  final endM = (h + 1) * 60;
                  final isOn = local.contains(startM);

                  return InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () {
                      // toggling happens in modal setState below via StatefulBuilder
                    },
                    child: Container(
                      width: 120,
                      margin: const EdgeInsets.only(right: 10),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: isOn ? actionOrange.withOpacity(0.10) : appBg,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: isOn ? actionOrange.withOpacity(0.35) : uiBorder.withOpacity(0.9),
                        ),
                      ),
                      child: Row(
                        children: [
                          Checkbox(
                            value: isOn,
                            activeColor: actionOrange,
                            onChanged: (_) {},
                          ),
                          Expanded(
                            child: Text(
                              '${_two(h)}-${_two(h + 1)}',
                              style: TextStyle(
                                fontWeight: FontWeight.w900,
                                color: isOn ? actionOrange : primaryBlue,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ],
        ),
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
            // helper toggle (needs setModal)
            void toggleHour(int h) {
              final startM = h * 60;
              if (local.contains(startM)) {
                local.remove(startM);
              } else {
                // Only allow full-hour slots inside range
                if (h >= startHour && h < endHour) {
                  local.add(startM);
                }
              }
            }

            Widget rowWithToggle(String title, List<int> hours) {
              if (hours.isEmpty) return const SizedBox.shrink();

              return Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: uiBorder.withOpacity(0.85)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontWeight: FontWeight.w900, color: primaryBlue)),
                    const SizedBox(height: 10),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: hours.map((h) {
                          final startM = h * 60;
                          final isOn = local.contains(startM);

                          return InkWell(
                            borderRadius: BorderRadius.circular(14),
                            onTap: () => setModal(() => toggleHour(h)),
                            child: Container(
                              width: 120,
                              margin: const EdgeInsets.only(right: 10),
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: isOn ? actionOrange.withOpacity(0.10) : appBg,
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: isOn ? actionOrange.withOpacity(0.35) : uiBorder.withOpacity(0.9),
                                ),
                              ),
                              child: Row(
                                children: [
                                  Checkbox(
                                    value: isOn,
                                    activeColor: actionOrange,
                                    onChanged: (_) => setModal(() => toggleHour(h)),
                                  ),
                                  Expanded(
                                    child: Text(
                                      '${_two(h)}-${_two(h + 1)}',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w900,
                                        color: isOn ? actionOrange : primaryBlue,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ],
                ),
              );
            }

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
                                  '$label timetable',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w900,
                                    color: primaryBlue,
                                    fontSize: 16,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Tick the 1-hour slots you can teach (weekly repeating).',
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
                              '${local.length} slot${local.length == 1 ? '' : 's'}',
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

                    // quick actions
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
                              // Select all for this day
                              final all = <int>{};
                              for (int h = startHour; h < endHour; h++) {
                                all.add(h * 60);
                              }
                              setModal(() {
                                local
                                  ..clear()
                                  ..addAll(all);
                              });
                            },
                            icon: const Icon(Icons.done_all_rounded),
                            label: const Text('Select all', style: TextStyle(fontWeight: FontWeight.w900)),
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
                            onPressed: local.isEmpty ? null : () => setModal(() => local.clear()),
                            icon: const Icon(Icons.delete_outline_rounded),
                            label: const Text('Clear day', style: TextStyle(fontWeight: FontWeight.w900)),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 12),

                    // timetable sections
                    ConstrainedBox(
                      constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.55),
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          rowWithToggle('Morning', morningHours),
                          const SizedBox(height: 12),
                          rowWithToggle('Afternoon / Evening', afternoonHours),
                        ],
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
                                weekSlots[dayKey] = <int>{...local};
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
                      'Tap a day and tick the 1-hour slots you can teach.\n'
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
                  return _DayCardSlots(
                    label: label,
                    slotCount: (weekSlots[dk] ?? <int>{}).length,
                    preview: _previewSlots(weekSlots[dk] ?? <int>{}),
                    onTap: saving ? null : () => _openDayEditor(dk, label),
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

  String _previewSlots(Set<int> slots) {
    if (slots.isEmpty) return 'No slots selected';
    final sorted = slots.toList()..sort();
    // show first 6
    final take = sorted.take(6).map((m) => _fmt(_minutesToTime(m))).toList();
    final more = sorted.length > 6 ? ' …' : '';
    return '${take.join(', ')}$more';
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
        final count = (weekSlots[dk] ?? <int>{}).length;

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

class _DayCardSlots extends StatelessWidget {
  const _DayCardSlots({
    required this.label,
    required this.slotCount,
    required this.preview,
    required this.onTap,
  });

  final String label;
  final int slotCount;
  final String preview;
  final VoidCallback? onTap;

  static const primaryBlue = Color(0xFF1A2B48);
  static const actionOrange = Color(0xFFF98D28);
  static const uiBorder = Color(0xFFD1D9E0);

  @override
  Widget build(BuildContext context) {
    final has = slotCount > 0;

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
                  Text(
                    preview,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: Colors.grey.shade700,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: has ? actionOrange.withOpacity(0.10) : const Color(0xFFF4F7F9),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: (has ? actionOrange : uiBorder).withOpacity(0.35)),
              ),
              child: Text(
                '$slotCount',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  color: has ? actionOrange : primaryBlue.withOpacity(0.6),
                  fontSize: 12,
                ),
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