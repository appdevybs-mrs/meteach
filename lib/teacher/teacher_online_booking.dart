// ✅ NEW FILE: lib/teacher/teacher_online_booking.dart
// Teacher creates ONLINE booking slots (NOT the in-class schedule)
//
// Reads:
// - users/<uid>/courses   (teacher assigned courses)
// - courses               (optional: for level/category text)
// - booking_curriculum/<courseId>  (to load totalSessions + session titles)
//
// Writes:
// - booking_slots/<autoId>
//
// Rules (v1):
// - Teacher can create OPEN slots.
// - Teacher can delete only if slot is still open and not booked.

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

class TeacherOnlineBookingScreen extends StatefulWidget {
  const TeacherOnlineBookingScreen({super.key});

  @override
  State<TeacherOnlineBookingScreen> createState() => _TeacherOnlineBookingScreenState();
}

class _TeacherOnlineBookingScreenState extends State<TeacherOnlineBookingScreen> {
  // ===== Brand colors (same style as teacher/admin) =====
  static const primaryBlue = Color(0xFF1A2B48);
  static const actionOrange = Color(0xFFF98D28);
  static const appBg = Color(0xFFF4F7F9);
  static const uiBorder = Color(0xFFD1D9E0);

  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  bool loading = true;
  bool loadingPlan = false;
  bool saving = false;

  // teacher identity
  String myUid = '';
  String myName = 'Teacher';

  // Teacher assigned courses (from users/<uid>/courses)
  List<_CoursePick> myCourses = [];
  String? selectedCourseId;

  // booking plan (from booking_curriculum/<courseId>)
  int planTotalSessions = 0;
  Map<int, String> planSessionTitles = {}; // sessionNo -> title
  int? selectedSessionNo;

  // form
  DateTime? selectedDate; // date part
  TimeOfDay? selectedTime; // time part
  final durationC = TextEditingController(text: '60'); // default 60 minutes

  // list
  List<_SlotItem> mySlots = [];
  bool loadingSlots = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    durationC.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _init() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      _toast('Not logged in.');
      setState(() => loading = false);
      return;
    }

    myUid = uid;
    await _loadMyName();
    await _loadMyCourses();
    await _loadMySlots();

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
    setState(() => loading = true);

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

          final courseId = (m['id'] ?? '').toString().trim();
          if (courseId.isEmpty) continue;

          final title = (m['title'] ?? '').toString().trim();
          final code = (m['course_code'] ?? '').toString().trim();

          out.add(_CoursePick(
            id: courseId,
            title: title.isEmpty ? 'Untitled' : title,
            code: code,
          ));
        }
      }

      // Sort by title
      out.sort((a, b) => a.title.compareTo(b.title));

      setState(() {
        myCourses = out;
        selectedCourseId ??= myCourses.isNotEmpty ? myCourses.first.id : null;
        // reset plan when course changes
        planTotalSessions = 0;
        planSessionTitles = {};
        selectedSessionNo = null;
      });

      if (myCourses.isEmpty) {
        _toast('No courses assigned to this teacher in users/$myUid/courses');
      }
    } catch (e) {
      _toast('Failed to load teacher courses: $e');
    }
  }

  Future<void> _loadBookingPlan() async {
    final courseId = selectedCourseId;
    if (courseId == null || courseId.isEmpty) {
      _toast('Select a course first.');
      return;
    }

    setState(() {
      loadingPlan = true;
      planTotalSessions = 0;
      planSessionTitles = {};
      selectedSessionNo = null;
    });

    try {
      final snap = await _db.child('booking_curriculum/$courseId').get();
      final v = snap.value;

      if (v is! Map) {
        _toast('No booking curriculum found at booking_curriculum/$courseId');
        return;
      }

      final m = v.map((k, vv) => MapEntry(k.toString(), vv));
      final total = _toInt(m['totalSessions']);
      final sessions = m['sessions'];

      final Map<int, String> titles = {};

      if (sessions is Map) {
        final sessMap = sessions.map((k, vv) => MapEntry(k.toString(), vv));
        for (final e in sessMap.entries) {
          final key = int.tryParse(e.key) ?? 0;
          final val = e.value;
          if (key <= 0) continue;
          if (val is Map) {
            final mm = val.map((kk, vvv) => MapEntry(kk.toString(), vvv));
            final t = (mm['sessionTitle'] ?? '').toString().trim();
            titles[key] = t.isEmpty ? 'Session $key' : t;
          } else {
            titles[key] = 'Session $key';
          }
        }
      }

      final maxNo = total > 0 ? total : (titles.keys.isEmpty ? 0 : titles.keys.reduce((a, b) => a > b ? a : b));

      setState(() {
        planTotalSessions = maxNo;
        planSessionTitles = titles;
        selectedSessionNo = maxNo > 0 ? 1 : null;
      });

      _toast('Loaded booking plan: $maxNo sessions ✅');
    } catch (e) {
      _toast('Failed loading booking plan: $e');
    } finally {
      if (!mounted) return;
      setState(() => loadingPlan = false);
    }
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      firstDate: now.subtract(const Duration(days: 0)),
      lastDate: now.add(const Duration(days: 365)),
      initialDate: selectedDate ?? now,
    );
    if (picked == null) return;
    setState(() => selectedDate = DateTime(picked.year, picked.month, picked.day));
  }

  Future<void> _pickTime() async {
    final now = TimeOfDay.now();
    final picked = await showTimePicker(
      context: context,
      initialTime: selectedTime ?? now,
    );
    if (picked == null) return;
    setState(() => selectedTime = picked);
  }

  DateTime? _buildStartDateTime() {
    if (selectedDate == null || selectedTime == null) return null;
    final d = selectedDate!;
    final t = selectedTime!;
    return DateTime(d.year, d.month, d.day, t.hour, t.minute);
  }

  Future<void> _publishSlot() async {
    final courseId = selectedCourseId;
    if (courseId == null || courseId.isEmpty) {
      _toast('Select a course first.');
      return;
    }

    if (planTotalSessions <= 0) {
      _toast('Load booking plan first.');
      return;
    }

    final sNo = selectedSessionNo;
    if (sNo == null || sNo <= 0 || sNo > planTotalSessions) {
      _toast('Select a valid session number.');
      return;
    }

    final start = _buildStartDateTime();
    if (start == null) {
      _toast('Pick date + time first.');
      return;
    }

    final dur = int.tryParse(durationC.text.trim()) ?? 60;
    final durationMin = dur <= 0 ? 60 : dur;
    final end = start.add(Duration(minutes: durationMin));

    // For UI: get course title from assigned list
    final course = myCourses.firstWhere(
          (c) => c.id == courseId,
      orElse: () => _CoursePick(id: courseId, title: 'Course', code: ''),
    );

    final sessionTitle = planSessionTitles[sNo] ?? 'Session $sNo';

    setState(() => saving = true);
    try {
      final newRef = _db.child('booking_slots').push();

      await newRef.set({
        'courseId': courseId,
        'courseTitle': course.title,
        'courseCode': course.code,
        'teacherId': myUid,
        'teacherName': myName,
        'sessionNo': sNo,
        'sessionTitle': sessionTitle,
        'startAt': start.millisecondsSinceEpoch,
        'endAt': end.millisecondsSinceEpoch,
        'durationMinutes': durationMin,
        'status': 'open',
        'bookedByUid': null,
        'bookedAt': null,
        'createdAt': ServerValue.timestamp,
        'updatedAt': ServerValue.timestamp,
      });

      _toast('Slot published ✅');
      await _loadMySlots();
    } catch (e) {
      _toast('Publish failed: $e');
    } finally {
      if (!mounted) return;
      setState(() => saving = false);
    }
  }

  Future<void> _loadMySlots() async {
    setState(() => loadingSlots = true);

    try {
      final snap = await _db.child('booking_slots').get();
      final v = snap.value;

      final out = <_SlotItem>[];

      if (v is Map) {
        final raw = Map<dynamic, dynamic>.from(v);
        raw.forEach((slotId, slotVal) {
          if (slotVal is! Map) return;
          final m = slotVal.map((k, vv) => MapEntry(k.toString(), vv));

          final teacherId = (m['teacherId'] ?? '').toString().trim();
          if (teacherId != myUid) return;

          final startAt = _toInt(m['startAt']);
          final endAt = _toInt(m['endAt']);
          if (startAt <= 0) return;

          out.add(
            _SlotItem(
              id: slotId.toString(),
              courseTitle: (m['courseTitle'] ?? '').toString(),
              courseId: (m['courseId'] ?? '').toString(),
              sessionNo: _toInt(m['sessionNo']),
              sessionTitle: (m['sessionTitle'] ?? '').toString(),
              startAt: startAt,
              endAt: endAt,
              status: (m['status'] ?? 'open').toString(),
              bookedByUid: (m['bookedByUid'] ?? '').toString(),
            ),
          );
        });
      }

      out.sort((a, b) => a.startAt.compareTo(b.startAt));

      setState(() => mySlots = out);
    } catch (e) {
      _toast('Failed loading slots: $e');
    } finally {
      if (!mounted) return;
      setState(() => loadingSlots = false);
    }
  }

  Future<bool> _confirmDelete() async {
    return (await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete slot?'),
        content: const Text('This will remove the slot completely.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    )) ??
        false;
  }

  Future<void> _deleteSlot(_SlotItem slot) async {
    // only delete if open + not booked
    final isOpen = slot.status.toLowerCase().trim() == 'open';
    final isBooked = slot.bookedByUid.trim().isNotEmpty;
    if (!isOpen || isBooked) {
      _toast('Cannot delete: slot is booked or not open.');
      return;
    }

    final ok = await _confirmDelete();
    if (!ok) return;

    try {
      await _db.child('booking_slots/${slot.id}').remove();
      _toast('Slot deleted ✅');
      await _loadMySlots();
    } catch (e) {
      _toast('Delete failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final courseId = selectedCourseId;
    final course = myCourses.where((c) => c.id == courseId).isNotEmpty
        ? myCourses.firstWhere((c) => c.id == courseId)
        : null;

    final start = _buildStartDateTime();

    return Scaffold(
      backgroundColor: appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: primaryBlue),
        title: const Text(
          'Online Booking',
          style: TextStyle(color: primaryBlue, fontWeight: FontWeight.w900),
        ),
        actions: [
          IconButton(
            tooltip: 'Reload',
            onPressed: (loading || saving) ? null : () async {
              await _loadMyCourses();
              await _loadMySlots();
            },
            icon: const Icon(Icons.refresh_rounded, color: primaryBlue),
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
            title: '1) Select Course',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _courseDropdown(),
                const SizedBox(height: 10),
                if (course != null)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: appBg,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: uiBorder),
                    ),
                    child: Text(
                      'Selected:\n'
                          '- ${course.title}\n'
                          '${course.code.isEmpty ? '' : '- Code: ${course.code}\n'}'
                          '\nNext: Load booking plan.',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    OutlinedButton.icon(
                      onPressed: loadingPlan || saving ? null : _loadBookingPlan,
                      icon: loadingPlan
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.download_rounded, color: primaryBlue),
                      label: const Text(
                        'Load booking plan',
                        style: TextStyle(color: primaryBlue, fontWeight: FontWeight.w900),
                      ),
                    ),
                    if (planTotalSessions > 0)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: uiBorder.withOpacity(0.8)),
                        ),
                        child: Text(
                          'Plan: $planTotalSessions sessions',
                          style: const TextStyle(fontWeight: FontWeight.w900, color: primaryBlue),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          _CardBox(
            title: '2) Create Slot',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (planTotalSessions <= 0)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: appBg,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: uiBorder),
                    ),
                    child: const Text(
                      'Load a booking plan first.\n'
                          'It comes from: booking_curriculum/<courseId>',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  )
                else ...[
                  _sessionNoDropdown(),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: saving ? null : _pickDate,
                          icon: const Icon(Icons.event_rounded, color: primaryBlue),
                          label: Text(
                            selectedDate == null
                                ? 'Pick Date'
                                : '${selectedDate!.year}-${_two(selectedDate!.month)}-${_two(selectedDate!.day)}',
                            style: const TextStyle(color: primaryBlue, fontWeight: FontWeight.w900),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: saving ? null : _pickTime,
                          icon: const Icon(Icons.schedule_rounded, color: primaryBlue),
                          label: Text(
                            selectedTime == null ? 'Pick Time' : selectedTime!.format(context),
                            style: const TextStyle(color: primaryBlue, fontWeight: FontWeight.w900),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: durationC,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Duration (minutes)',
                      hintText: 'Example: 60',
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (start != null)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: appBg,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: uiBorder),
                      ),
                      child: Text(
                        'Preview:\n'
                            '- ${course?.title ?? 'Course'}\n'
                            '- Session ${selectedSessionNo ?? '-'}: ${planSessionTitles[selectedSessionNo ?? 0] ?? ''}\n'
                            '- ${start.toString()}',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: actionOrange,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                      onPressed: saving ? null : _publishSlot,
                      icon: saving
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.publish_rounded),
                      label: Text(saving ? 'Publishing…' : 'Publish Slot'),
                    ),
                  ),
                ],
              ],
            ),
          ),

          const SizedBox(height: 12),

          _CardBox(
            title: '3) My Slots',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    OutlinedButton.icon(
                      onPressed: loadingSlots || saving ? null : _loadMySlots,
                      icon: loadingSlots
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.refresh_rounded, color: primaryBlue),
                      label: const Text(
                        'Refresh slots',
                        style: TextStyle(color: primaryBlue, fontWeight: FontWeight.w900),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: uiBorder.withOpacity(0.8)),
                      ),
                      child: Text(
                        'Total: ${mySlots.length}',
                        style: const TextStyle(fontWeight: FontWeight.w900, color: primaryBlue),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                if (mySlots.isEmpty)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: appBg,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: uiBorder),
                    ),
                    child: const Text(
                      'No slots yet.\nCreate your first slot above.',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  )
                else
                  Column(
                    children: mySlots.map((s) => _slotTile(s)).toList(),
                  ),
              ],
            ),
          ),

          const SizedBox(height: 14),
        ],
      ),
    );
  }

  Widget _courseDropdown() {
    if (myCourses.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: appBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: uiBorder),
        ),
        child: const Text(
          'No courses assigned to you.\nAsk admin to assign courses in users/<uid>/courses',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
      );
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
        onChanged: (v) {
          setState(() {
            selectedCourseId = v;
            // reset plan when course changes
            planTotalSessions = 0;
            planSessionTitles = {};
            selectedSessionNo = null;
          });
        },
      ),
    );
  }

  Widget _sessionNoDropdown() {
    final items = List<int>.generate(planTotalSessions, (i) => i + 1);

    final safeValue = (selectedSessionNo != null && selectedSessionNo! >= 1 && selectedSessionNo! <= planTotalSessions)
        ? selectedSessionNo
        : (items.isNotEmpty ? items.first : null);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: uiBorder),
      ),
      child: DropdownButton<int>(
        value: safeValue,
        isExpanded: true,
        underline: const SizedBox.shrink(),
        items: items.map((n) {
          final t = (planSessionTitles[n] ?? '').trim();
          return DropdownMenuItem(
            value: n,
            child: Text(
              t.isEmpty ? 'Session $n' : 'Session $n — $t',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          );
        }).toList(),
        onChanged: (v) => setState(() => selectedSessionNo = v),
      ),
    );
  }

  Widget _slotTile(_SlotItem s) {
    final dt = DateTime.fromMillisecondsSinceEpoch(s.startAt);
    final dateStr = '${dt.year}-${_two(dt.month)}-${_two(dt.day)}';
    final timeStr = '${_two(dt.hour)}:${_two(dt.minute)}';

    final status = s.status.toLowerCase().trim();
    final isOpen = status == 'open';
    final isBooked = (s.bookedByUid.trim().isNotEmpty) || status == 'booked';

    Color badgeBg = appBg;
    Color badgeBorder = uiBorder;
    Color badgeText = primaryBlue;

    if (isBooked) {
      badgeBg = Colors.orange.withOpacity(0.10);
      badgeBorder = Colors.orange.withOpacity(0.25);
      badgeText = Colors.orange.shade800;
    } else if (!isOpen) {
      badgeBg = Colors.grey.withOpacity(0.12);
      badgeBorder = Colors.grey.withOpacity(0.25);
      badgeText = Colors.grey.shade700;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
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
              border: Border.all(color: primaryBlue.withOpacity(0.12)),
            ),
            child: const Icon(Icons.video_call_rounded, color: primaryBlue),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${s.courseTitle} • Session ${s.sessionNo}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w900, color: primaryBlue),
                ),
                const SizedBox(height: 4),
                Text(
                  '${s.sessionTitle.isEmpty ? '' : s.sessionTitle + ' • '} $dateStr • $timeStr',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontWeight: FontWeight.w700, color: Colors.grey.shade700, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: badgeBg,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: badgeBorder),
                ),
                child: Text(
                  status.isEmpty ? 'open' : status,
                  style: TextStyle(fontWeight: FontWeight.w900, color: badgeText, fontSize: 12),
                ),
              ),
              const SizedBox(height: 6),
              InkWell(
                onTap: saving ? null : () => _deleteSlot(s),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.red.withOpacity(0.10),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: Colors.red.withOpacity(0.25)),
                  ),
                  child: Text(
                    'Delete',
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      color: (s.status.toLowerCase() == 'open' && s.bookedByUid.trim().isEmpty)
                          ? Colors.red
                          : Colors.red.withOpacity(0.45),
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static int _toInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  static String _two(int n) => n < 10 ? '0$n' : '$n';
}

class _CoursePick {
  final String id;
  final String title;
  final String code;

  _CoursePick({required this.id, required this.title, required this.code});
}

class _SlotItem {
  final String id;
  final String courseId;
  final String courseTitle;
  final int sessionNo;
  final String sessionTitle;
  final int startAt;
  final int endAt;
  final String status;
  final String bookedByUid;

  _SlotItem({
    required this.id,
    required this.courseId,
    required this.courseTitle,
    required this.sessionNo,
    required this.sessionTitle,
    required this.startAt,
    required this.endAt,
    required this.status,
    required this.bookedByUid,
  });
}

class _CardBox extends StatelessWidget {
  const _CardBox({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFD1D9E0)),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontWeight: FontWeight.w900,
              color: Color(0xFF1A2B48),
            ),
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}