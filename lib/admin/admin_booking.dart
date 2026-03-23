import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import '../shared/app_feedback.dart';

class AdminBookingScreen extends StatefulWidget {
  const AdminBookingScreen({super.key});

  @override
  State<AdminBookingScreen> createState() => _AdminBookingScreenState();
}

class _AdminBookingScreenState extends State<AdminBookingScreen> {
  // ===== Colors =====
  static const primaryBlue = Color(0xFF1A2B48);
  static const actionOrange = Color(0xFFF98D28);
  static const appBg = Color(0xFFF4F7F9);
  static const uiBorder = Color(0xFFD1D9E0);
  static const successGreen = Color(0xFF2F9E44);

  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  // ===== Data =====
  bool loadingCourses = true;
  bool loadingBookings = false;
  bool busyAction = false;

  List<_CourseItem> allCourses = [];
  String? selectedCourseId;

  List<_AdminBookedSlot> bookedSlots = [];
  Map<String, _LearnerProfile> learnerCache = {};

  /// courseId -> has at least one booking
  Map<String, bool> courseHasBookings = {};

  final TextEditingController searchC = TextEditingController();

  String levelFilter = 'all';
  String teacherFilter = 'all';
  String dateFilter = 'all'; // all | today | thisWeek | future
  bool onlyMultiLearner = false;

  @override
  void initState() {
    super.initState();
    _loadCourses();
    searchC.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    searchC.dispose();
    super.dispose();
  }

  // ========================= Helpers =========================

  void _toast(String msg) {
    if (!mounted) return;
    AppToast.fromSnackBar(context, 
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  String _two(int n) => n < 10 ? '0$n' : '$n';

  String _dateKey(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';

  String _friendlyDate(DateTime d) {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${days[d.weekday - 1]} ${_two(d.day)} ${months[d.month - 1]}';
  }

  String _friendlyDateLong(DateTime d) {
    const days = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${days[d.weekday - 1]}, ${_two(d.day)} ${months[d.month - 1]} ${d.year}';
  }

  int _toInt(dynamic v, {int fallback = 0}) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? fallback;
  }

  DateTime? _parseSlotStart(String dayKey, String hhmm) {
    try {
      final dp = dayKey.split('-');
      if (dp.length != 3) return null;

      final y = int.tryParse(dp[0]);
      final m = int.tryParse(dp[1]);
      final d = int.tryParse(dp[2]);

      final tp = hhmm.split(':');
      if (tp.length != 2) return null;

      final hh = int.tryParse(tp[0]);
      final mm = int.tryParse(tp[1]);

      if (y == null || m == null || d == null || hh == null || mm == null)
        return null;

      return DateTime(y, m, d, hh, mm);
    } catch (_) {
      return null;
    }
  }

  String _weekdayKey(DateTime d) {
    switch (d.weekday) {
      case DateTime.monday:
        return 'mon';
      case DateTime.tuesday:
        return 'tue';
      case DateTime.wednesday:
        return 'wed';
      case DateTime.thursday:
        return 'thu';
      case DateTime.friday:
        return 'fri';
      case DateTime.saturday:
        return 'sat';
      default:
        return 'sun';
    }
  }

  bool _sameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  bool _isThisWeek(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final startOfWeek = today.subtract(Duration(days: today.weekday - 1));
    final endOfWeek = startOfWeek.add(const Duration(days: 7));
    return !d.isBefore(startOfWeek) && d.isBefore(endOfWeek);
  }

  DatabaseReference _reservationsRootRef(String cid) =>
      _db.child('booking_reservations/$cid');
  DatabaseReference _reservationsRef(String cid, String dayKey, String hhmm) =>
      _db.child('booking_reservations/$cid/$dayKey/$hhmm');

  _CourseItem? _selectedCourse() {
    final cid = selectedCourseId;
    if (cid == null) return null;
    for (final c in allCourses) {
      if (c.id == cid) return c;
    }
    return null;
  }

  String _shortCourseLabel(_CourseItem c) {
    final parts = <String>[];
    if (c.levelText.isNotEmpty) parts.add(c.levelText);
    if (c.category.isNotEmpty) parts.add(c.category);
    if (parts.isEmpty) return c.title;
    return '${parts.join(' • ')} • ${c.title}';
  }

  String _statusLabelForSlot(_AdminBookedSlot s) {
    if (s.start.isBefore(DateTime.now())) return 'Past';
    if (s.learnerCount >= 6) return 'Full';
    if (s.learnerCount >= 2) return 'Group';
    return 'Open';
  }

  Color _statusColorForSlot(_AdminBookedSlot s) {
    if (s.start.isBefore(DateTime.now())) return Colors.grey.shade700;
    if (s.learnerCount >= 6) return Colors.red.shade700;
    if (s.learnerCount >= 2) return actionOrange;
    return successGreen;
  }

  void _clearFilters() {
    setState(() {
      levelFilter = 'all';
      teacherFilter = 'all';
      dateFilter = 'all';
      onlyMultiLearner = false;
      searchC.clear();
    });
  }

  // ========================= Load Courses =========================

  Future<void> _loadCourses() async {
    setState(() => loadingCourses = true);

    try {
      final coursesSnap = await _db.child('courses').get();
      final reservationsSnap = await _db.child('booking_reservations').get();

      final List<_CourseItem> out = [];
      final Map<String, bool> hasBookings = {};

      if (reservationsSnap.value is Map) {
        final root = (reservationsSnap.value as Map).map(
          (k, vv) => MapEntry(k.toString(), vv),
        );

        for (final entry in root.entries) {
          final cid = entry.key;
          final courseNode = entry.value;
          bool found = false;

          if (courseNode is Map) {
            final days = courseNode.map((k, vv) => MapEntry(k.toString(), vv));
            for (final dayEntry in days.entries) {
              if (dayEntry.value is! Map) continue;
              final times = (dayEntry.value as Map).map(
                (k, vv) => MapEntry(k.toString(), vv),
              );

              for (final timeEntry in times.entries) {
                if (timeEntry.value is! Map) continue;
                final m = (timeEntry.value as Map).map(
                  (k, vv) => MapEntry(k.toString(), vv),
                );
                final learnersRaw = m['learners'];
                if (learnersRaw is Map && learnersRaw.isNotEmpty) {
                  found = true;
                  break;
                }
              }
              if (found) break;
            }
          }

          hasBookings[cid] = found;
        }
      }

      final v = coursesSnap.value;

      if (v is Map) {
        final root = v.map((k, vv) => MapEntry(k.toString(), vv));

        root.forEach((courseId, courseVal) {
          if (courseVal is! Map) return;

          final m = courseVal.map((k, vv) => MapEntry(k.toString(), vv));
          final status = (m['status'] ?? '').toString().trim().toLowerCase();
          if (status.isNotEmpty && status != 'published') return;

          final title = (m['title'] ?? '').toString().trim();
          final level = (m['level'] ?? '').toString().trim();
          final category = (m['category'] ?? '').toString().trim();
          final orderIndex = (m['order_index'] is num)
              ? (m['order_index'] as num).toInt()
              : 999;

          out.add(
            _CourseItem(
              id: courseId,
              title: title.isEmpty ? 'Untitled' : title,
              levelText: level,
              category: category,
              orderIndex: orderIndex,
            ),
          );

          hasBookings.putIfAbsent(courseId, () => false);
        });
      }

      out.sort((a, b) {
        if (a.orderIndex != b.orderIndex)
          return a.orderIndex.compareTo(b.orderIndex);
        return a.title.compareTo(b.title);
      });

      String? nextSelected = selectedCourseId;
      if (nextSelected == null || !out.any((c) => c.id == nextSelected)) {
        nextSelected = out.isNotEmpty ? out.first.id : null;
      }

      setState(() {
        allCourses = out;
        courseHasBookings = hasBookings;
        selectedCourseId = nextSelected;
      });

      if (selectedCourseId != null) {
        await _loadBookingsForCourse(selectedCourseId!);
      }
    } catch (e) {
      _toast('Failed loading courses: $e');
    } finally {
      if (!mounted) return;
      setState(() => loadingCourses = false);
    }
  }

  // ========================= Load Bookings =========================

  Future<void> _loadBookingsForCourse(String cid) async {
    setState(() {
      loadingBookings = true;
      bookedSlots = [];
      teacherFilter = 'all';
    });

    try {
      final snap = await _reservationsRootRef(cid).get();
      final v = snap.value;

      final List<_AdminBookedSlot> out = [];

      if (v is Map) {
        final days = v.map((k, vv) => MapEntry(k.toString(), vv));

        for (final dayEntry in days.entries) {
          final dayKey = dayEntry.key;
          final dayNode = dayEntry.value;
          if (dayNode is! Map) continue;

          final times = dayNode.map((k, vv) => MapEntry(k.toString(), vv));

          for (final timeEntry in times.entries) {
            final hhmm = timeEntry.key;
            final slotVal = timeEntry.value;
            if (slotVal is! Map) continue;

            final m = slotVal.map((k, vv) => MapEntry(k.toString(), vv));

            final learnersRaw = m['learners'];
            if (learnersRaw is! Map) continue;

            final learnersMap = learnersRaw.map(
              (k, vv) => MapEntry(k.toString(), vv),
            );
            final learnerUids = learnersMap.keys
                .map((e) => e.toString())
                .toList();
            if (learnerUids.isEmpty) continue;

            final start = _parseSlotStart(dayKey, hhmm);
            if (start == null) continue;

            out.add(
              _AdminBookedSlot(
                courseId: cid,
                dayKey: dayKey,
                time: hhmm,
                start: start,
                teacherId: (m['teacherId'] ?? '').toString().trim(),
                teacherName: (m['teacherName'] ?? 'Teacher').toString().trim(),
                sessionNo: _toInt(m['sessionNo'], fallback: 0),
                learnerUids: learnerUids,
                createdAt: _toInt(m['createdAt'], fallback: 0),
              ),
            );
          }
        }
      }

      out.sort((a, b) => a.start.compareTo(b.start));

      if (!mounted) return;
      setState(() => bookedSlots = out);
    } catch (e) {
      _toast('Failed loading bookings: $e');
    } finally {
      if (!mounted) return;
      setState(() => loadingBookings = false);
    }
  }

  // ========================= Learner Profiles =========================

  Future<void> _ensureLearnerProfiles(List<String> uids) async {
    final missing = <String>[];
    for (final uid in uids) {
      if (!learnerCache.containsKey(uid)) missing.add(uid);
    }
    if (missing.isEmpty) return;

    try {
      final futures = missing.map((uid) async {
        final snap = await _db.child('users/$uid').get();

        if (!snap.exists || snap.value is! Map) {
          return MapEntry(
            uid,
            _LearnerProfile(
              uid: uid,
              fullName: 'Unknown learner',
              serial: '',
              email: '',
              phone: '',
              status: '',
            ),
          );
        }

        final m = (snap.value as Map).map(
          (k, vv) => MapEntry(k.toString(), vv),
        );

        final first = (m['first_name'] ?? '').toString().trim();
        final last = (m['last_name'] ?? '').toString().trim();
        final fullName = '$first $last'.trim();

        return MapEntry(
          uid,
          _LearnerProfile(
            uid: uid,
            fullName: fullName.isEmpty ? 'Unknown learner' : fullName,
            serial: (m['serial'] ?? '').toString().trim(),
            email: (m['email'] ?? '').toString().trim(),
            phone: (m['phone1'] ?? '').toString().trim(),
            status: (m['status'] ?? '').toString().trim(),
          ),
        );
      }).toList();

      final entries = await Future.wait(futures);

      if (!mounted) return;
      setState(() {
        for (final e in entries) {
          learnerCache[e.key] = e.value;
        }
      });
    } catch (e) {
      _toast('Failed loading learner profiles: $e');
    }
  }

  // ========================= Filters =========================

  List<String> _levelOptionsWithBookingsOnly() {
    final set = <String>{};

    for (final c in allCourses) {
      final hasBooking = courseHasBookings[c.id] == true;
      if (!hasBooking) continue;
      if (c.levelText.trim().isEmpty) continue;
      set.add(c.levelText.trim());
    }

    final list = set.toList()..sort();
    return list;
  }

  List<_CourseItem> _coursesForSelectedLevel() {
    if (levelFilter == 'all') return allCourses;
    return allCourses.where((c) => c.levelText == levelFilter).toList();
  }

  List<_AdminBookedSlot> _filteredSlots() {
    final q = searchC.text.trim().toLowerCase();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final course = _selectedCourse();

    final out = <_AdminBookedSlot>[];

    for (final s in bookedSlots) {
      if (teacherFilter != 'all' && s.teacherId != teacherFilter) continue;
      if (onlyMultiLearner && s.learnerCount < 2) continue;

      if (dateFilter == 'today' && !_sameDay(s.start, today)) continue;
      if (dateFilter == 'thisWeek' && !_isThisWeek(s.start)) continue;
      if (dateFilter == 'future' && !s.start.isAfter(now)) continue;

      if (levelFilter != 'all') {
        if (course == null || course.levelText != levelFilter) continue;
      }

      if (q.isNotEmpty) {
        final haystack = [
          s.teacherName,
          s.teacherId,
          s.time,
          s.dayKey,
          s.sessionNo.toString(),
          s.learnerCount.toString(),
          _friendlyDate(s.start),
          _friendlyDateLong(s.start),
          _statusLabelForSlot(s),
        ].join(' ').toLowerCase();

        if (!haystack.contains(q)) continue;
      }

      out.add(s);
    }

    return out;
  }

  // ========================= Cancel =========================

  Future<void> _cancelLearnerFromSlot(
    _AdminBookedSlot slot,
    String learnerUid,
    BuildContext detailsSheetContext,
  ) async {
    if (busyAction) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Cancel booking'),
        content: Text(
          'Remove this learner from:\n\n${_friendlyDateLong(slot.start)} at ${slot.time}\nTeacher: ${slot.teacherName}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('No'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Yes, Cancel'),
          ),
        ],
      ),
    );

    if (ok != true) return;

    setState(() => busyAction = true);

    try {
      final ref = _reservationsRef(slot.courseId, slot.dayKey, slot.time);

      final result = await ref.runTransaction((Object? currentData) {
        if (currentData is! Map) return Transaction.abort();

        final node = currentData.map((k, v) => MapEntry(k.toString(), v));
        final learnersRaw = node['learners'];
        if (learnersRaw is! Map) return Transaction.abort();

        final learners = learnersRaw.map((k, v) => MapEntry(k.toString(), v));
        if (!learners.containsKey(learnerUid)) return Transaction.abort();

        learners.remove(learnerUid);

        if (learners.isEmpty) {
          return Transaction.success(null);
        }

        node['learners'] = learners;
        return Transaction.success(node);
      });

      if (!result.committed) {
        _toast('Cancel failed.');
        return;
      }

      _toast('Booking canceled ✅');
      await _loadBookingsForCourse(slot.courseId);

      if (!mounted) return;
      if (Navigator.of(detailsSheetContext).canPop()) {
        Navigator.of(detailsSheetContext).pop();
      }
    } catch (e) {
      _toast('Cancel failed: $e');
    } finally {
      if (!mounted) return;
      setState(() => busyAction = false);
    }
  }

  // ========================= Reschedule =========================

  Future<List<_AvailSlot>> _buildAvailableSlotsForCourse(String cid) async {
    final now = DateTime.now();
    final List<_AvailSlot> out = [];

    try {
      final reservationsSnap = await _reservationsRootRef(cid).get();
      final Map<String, _ReservationSummary> summaries = {};

      if (reservationsSnap.value is Map) {
        final days = (reservationsSnap.value as Map).map(
          (k, vv) => MapEntry(k.toString(), vv),
        );

        for (final dayEntry in days.entries) {
          if (dayEntry.value is! Map) continue;
          final dayMap = (dayEntry.value as Map).map(
            (k, vv) => MapEntry(k.toString(), vv),
          );

          for (final timeEntry in dayMap.entries) {
            if (timeEntry.value is! Map) continue;
            final m = (timeEntry.value as Map).map(
              (k, vv) => MapEntry(k.toString(), vv),
            );

            final learnersRaw = m['learners'];
            int count = 0;
            if (learnersRaw is Map) count = learnersRaw.length;

            if (count <= 0) continue;

            final key = '${dayEntry.key}|${timeEntry.key}';
            final sessionNo = _toInt(m['sessionNo'], fallback: 0);

            summaries[key] = _ReservationSummary(
              bookedCount: count,
              groupSessionNo: sessionNo > 0 ? sessionNo : null,
            );
          }
        }
      }

      final availabilitySnap = await _db.child('booking_availability').get();
      if (!availabilitySnap.exists || availabilitySnap.value is! Map)
        return out;

      final root = (availabilitySnap.value as Map).map(
        (k, vv) => MapEntry(k.toString(), vv),
      );

      for (final teacherEntry in root.entries) {
        final teacherId = teacherEntry.key;
        final teacherNode = teacherEntry.value;
        if (teacherNode is! Map) continue;

        final tn = teacherNode.map((k, vv) => MapEntry(k.toString(), vv));

        final perCourse = tn[cid];
        if (perCourse is! Map) continue;

        final m = perCourse.map((k, vv) => MapEntry(k.toString(), vv));

        final teacherName =
            (m['teacherName'] ??
                    m['teacher_name'] ??
                    tn['teacherName'] ??
                    tn['teacher_name'] ??
                    'Teacher')
                .toString()
                .trim();

        int maxLearners = _toInt(m['maxLearnersPerSlot'], fallback: 0);
        if (maxLearners <= 0) maxLearners = 6;

        final week = m['week'];
        if (week is! Map) continue;

        final wm = week.map((k, vv) => MapEntry(k.toString(), vv));

        for (int i = 0; i < 21; i++) {
          final day = DateTime(
            now.year,
            now.month,
            now.day,
          ).add(Duration(days: i));
          final dayKey = _dateKey(day);
          final weekday = _weekdayKey(day);

          final rawList = wm[weekday];
          if (rawList is! List) continue;

          for (final item in rawList) {
            final hhmm = item.toString().trim();
            if (!hhmm.contains(':')) continue;

            final start = _parseSlotStart(dayKey, hhmm);
            if (start == null) continue;

            final key = '$dayKey|$hhmm';
            final summary = summaries[key];

            out.add(
              _AvailSlot(
                courseId: cid,
                dayKey: dayKey,
                time: hhmm,
                start: start,
                teacherId: teacherId,
                teacherName: teacherName.isEmpty ? 'Teacher' : teacherName,
                bookedCount: summary?.bookedCount ?? 0,
                groupSessionNo: summary?.groupSessionNo,
                maxLearnersPerSlot: maxLearners,
              ),
            );
          }
        }
      }
    } catch (e) {
      _toast('Failed loading available slots: $e');
    }

    out.sort((a, b) => a.start.compareTo(b.start));
    return out;
  }

  Future<void> _pickRescheduleTarget(
    _AdminBookedSlot sourceSlot,
    String learnerUid,
    BuildContext detailsSheetContext,
  ) async {
    final available = await _buildAvailableSlotsForCourse(sourceSlot.courseId);

    if (!mounted) return;

    final possible = available.where((s) {
      if (s.dayKey == sourceSlot.dayKey && s.time == sourceSlot.time)
        return false;
      if (s.start.isBefore(DateTime.now().subtract(const Duration(minutes: 1))))
        return false;
      if (s.groupSessionNo != null && s.groupSessionNo != sourceSlot.sessionNo)
        return false;
      if (s.isFull) return false;
      return true;
    }).toList();

    if (possible.isEmpty) {
      _toast('No valid target slots found.');
      return;
    }

    String query = '';

    final chosen = await showModalBottomSheet<_AvailSlot>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) {
        return StatefulBuilder(
          builder: (context, setInner) {
            final filtered = possible.where((s) {
              if (query.trim().isEmpty) return true;
              final q = query.trim().toLowerCase();
              final text =
                  '${s.teacherName} ${s.dayKey} ${s.time} ${_friendlyDateLong(s.start)}'
                      .toLowerCase();
              return text.contains(q);
            }).toList();

            return SafeArea(
              child: Padding(
                padding: EdgeInsets.only(
                  left: 14,
                  right: 14,
                  top: 8,
                  bottom: MediaQuery.of(context).padding.bottom + 10,
                ),
                child: Column(
                  children: [
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Choose new slot',
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 15,
                          color: primaryBlue,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      decoration: InputDecoration(
                        hintText: 'Search teacher / date / time',
                        isDense: true,
                        prefixIcon: const Icon(Icons.search_rounded),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: uiBorder),
                        ),
                      ),
                      onChanged: (v) => setInner(() => query = v),
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: filtered.isEmpty
                          ? const Center(
                              child: Text(
                                'No slots match your search.',
                                style: TextStyle(fontWeight: FontWeight.w800),
                              ),
                            )
                          : ListView.separated(
                              itemCount: filtered.length,
                              separatorBuilder: (_, _) =>
                                  const SizedBox(height: 8),
                              itemBuilder: (_, i) {
                                final s = filtered[i];
                                final cap = s.maxLearnersPerSlot <= 0
                                    ? 6
                                    : s.maxLearnersPerSlot;

                                return InkWell(
                                  borderRadius: BorderRadius.circular(14),
                                  onTap: () => Navigator.pop(context, s),
                                  child: Container(
                                    padding: const EdgeInsets.all(10),
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      borderRadius: BorderRadius.circular(14),
                                      border: Border.all(color: uiBorder),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          '${_friendlyDateLong(s.start)} • ${s.time}',
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w900,
                                            color: primaryBlue,
                                          ),
                                        ),
                                        const SizedBox(height: 3),
                                        Text(
                                          'Teacher: ${s.teacherName}',
                                          style: TextStyle(
                                            fontWeight: FontWeight.w700,
                                            color: Colors.grey.shade700,
                                          ),
                                        ),
                                        const SizedBox(height: 3),
                                        Text(
                                          s.groupSessionNo == null
                                              ? 'Empty slot • Capacity ${s.bookedCount}/$cap'
                                              : 'Session ${s.groupSessionNo} group • Capacity ${s.bookedCount}/$cap',
                                          style: TextStyle(
                                            fontWeight: FontWeight.w800,
                                            color: s.groupSessionNo == null
                                                ? successGreen
                                                : actionOrange,
                                          ),
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
            );
          },
        );
      },
    );

    if (chosen == null) return;

    await _moveLearnerToNewSlot(
      sourceSlot: sourceSlot,
      learnerUid: learnerUid,
      target: chosen,
      detailsSheetContext: detailsSheetContext,
    );
  }

  Future<void> _moveLearnerToNewSlot({
    required _AdminBookedSlot sourceSlot,
    required String learnerUid,
    required _AvailSlot target,
    required BuildContext detailsSheetContext,
  }) async {
    if (busyAction) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Reschedule booking'),
        content: Text(
          'Move this learner?\n\n'
          'From:\n${_friendlyDateLong(sourceSlot.start)} at ${sourceSlot.time}\n${sourceSlot.teacherName}\n\n'
          'To:\n${_friendlyDateLong(target.start)} at ${target.time}\n${target.teacherName}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('No'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Yes, Move'),
          ),
        ],
      ),
    );

    if (ok != true) return;

    setState(() => busyAction = true);

    try {
      final sourceRef = _reservationsRef(
        sourceSlot.courseId,
        sourceSlot.dayKey,
        sourceSlot.time,
      );
      final targetRef = _reservationsRef(
        target.courseId,
        target.dayKey,
        target.time,
      );

      final tx = await targetRef.runTransaction((Object? currentData) {
        final Map<String, dynamic> node = (currentData is Map)
            ? currentData.map((k, v) => MapEntry(k.toString(), v))
            : <String, dynamic>{};

        final Map<String, dynamic> learners = <String, dynamic>{};
        final learnersRaw = node['learners'];
        if (learnersRaw is Map) {
          learners.addAll(learnersRaw.map((k, v) => MapEntry(k.toString(), v)));
        }

        final existingSession = _toInt(node['sessionNo'], fallback: 0);
        if (existingSession > 0 && existingSession != sourceSlot.sessionNo) {
          return Transaction.abort();
        }

        final cap = target.maxLearnersPerSlot <= 0
            ? 6
            : target.maxLearnersPerSlot;
        if (!learners.containsKey(learnerUid) && learners.length >= cap) {
          return Transaction.abort();
        }

        learners[learnerUid] = true;
        node['teacherId'] = target.teacherId;
        node['teacherName'] = target.teacherName;
        node['sessionNo'] = sourceSlot.sessionNo;
        node['learners'] = learners;
        node['createdAt'] = ServerValue.timestamp;

        return Transaction.success(node);
      });

      if (!tx.committed) {
        _toast('Could not move learner to the selected slot.');
        return;
      }

      final removeTx = await sourceRef.runTransaction((Object? currentData) {
        if (currentData is! Map) return Transaction.abort();

        final node = currentData.map((k, v) => MapEntry(k.toString(), v));
        final learnersRaw = node['learners'];
        if (learnersRaw is! Map) return Transaction.abort();

        final learners = learnersRaw.map((k, v) => MapEntry(k.toString(), v));
        if (!learners.containsKey(learnerUid)) return Transaction.abort();

        learners.remove(learnerUid);

        if (learners.isEmpty) {
          return Transaction.success(null);
        }

        node['learners'] = learners;
        return Transaction.success(node);
      });

      if (!removeTx.committed) {
        _toast(
          'Moved to new slot, but old slot cleanup failed. Please refresh and check.',
        );
      } else {
        _toast('Booking moved ✅');
      }

      await _loadBookingsForCourse(sourceSlot.courseId);

      if (!mounted) return;
      if (Navigator.of(detailsSheetContext).canPop()) {
        Navigator.of(detailsSheetContext).pop();
      }
    } catch (e) {
      _toast('Reschedule failed: $e');
    } finally {
      if (!mounted) return;
      setState(() => busyAction = false);
    }
  }

  // ========================= Slot Details =========================

  Future<void> _openSlotDetails(_AdminBookedSlot slot) async {
    await _ensureLearnerProfiles(slot.learnerUids);

    if (!mounted) return;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetContext) {
        final bottomPad = MediaQuery.of(sheetContext).padding.bottom;

        final learners =
            slot.learnerUids
                .map(
                  (uid) =>
                      learnerCache[uid] ??
                      _LearnerProfile(
                        uid: uid,
                        fullName: uid,
                        serial: '',
                        email: '',
                        phone: '',
                        status: '',
                      ),
                )
                .toList()
              ..sort((a, b) => a.fullName.compareTo(b.fullName));

        return SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(14, 8, 14, bottomPad + 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '${_friendlyDateLong(slot.start)} • ${slot.time}',
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 15,
                      color: primaryBlue,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Teacher: ${slot.teacherName}',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: Colors.grey.shade700,
                    ),
                  ),
                ),
                const SizedBox(height: 3),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Session ${slot.sessionNo <= 0 ? '—' : slot.sessionNo} • ${slot.learnerCount} learner${slot.learnerCount == 1 ? '' : 's'}',
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      color: actionOrange,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Flexible(
                  child: learners.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.symmetric(vertical: 20),
                          child: Text(
                            'No learners found.',
                            style: TextStyle(fontWeight: FontWeight.w800),
                          ),
                        )
                      : ListView.separated(
                          shrinkWrap: true,
                          itemCount: learners.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 8),
                          itemBuilder: (_, i) {
                            final p = learners[i];

                            return Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(color: uiBorder),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          p.fullName,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w900,
                                            color: primaryBlue,
                                          ),
                                        ),
                                      ),
                                      if (p.status.isNotEmpty)
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 4,
                                          ),
                                          decoration: BoxDecoration(
                                            color:
                                                p.status.toLowerCase() ==
                                                    'active'
                                                ? const Color(0xFFEAF7EE)
                                                : const Color(0xFFFFF1E3),
                                            borderRadius: BorderRadius.circular(
                                              999,
                                            ),
                                          ),
                                          child: Text(
                                            p.status,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w900,
                                              fontSize: 11,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                  if (p.serial.isNotEmpty) ...[
                                    const SizedBox(height: 3),
                                    Text(
                                      p.serial,
                                      style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                        color: Colors.grey.shade700,
                                      ),
                                    ),
                                  ],
                                  if (p.email.isNotEmpty) ...[
                                    const SizedBox(height: 2),
                                    Text(
                                      p.email,
                                      style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                        color: Colors.grey.shade700,
                                      ),
                                    ),
                                  ],
                                  if (p.phone.isNotEmpty) ...[
                                    const SizedBox(height: 2),
                                    Text(
                                      p.phone,
                                      style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                        color: Colors.grey.shade700,
                                      ),
                                    ),
                                  ],
                                  const SizedBox(height: 8),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: OutlinedButton.icon(
                                          style: OutlinedButton.styleFrom(
                                            foregroundColor: primaryBlue,
                                            side: BorderSide(
                                              color: primaryBlue.withValues(alpha: 
                                                0.25,
                                              ),
                                            ),
                                            shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                            ),
                                            padding: const EdgeInsets.symmetric(
                                              vertical: 10,
                                            ),
                                          ),
                                          onPressed: busyAction
                                              ? null
                                              : () => _pickRescheduleTarget(
                                                  slot,
                                                  p.uid,
                                                  sheetContext,
                                                ),
                                          icon: const Icon(
                                            Icons.swap_horiz_rounded,
                                          ),
                                          label: const Text(
                                            'Reschedule',
                                            style: TextStyle(
                                              fontWeight: FontWeight.w900,
                                            ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: FilledButton.icon(
                                          style: FilledButton.styleFrom(
                                            backgroundColor:
                                                Colors.red.shade600,
                                            foregroundColor: Colors.white,
                                            shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                            ),
                                            padding: const EdgeInsets.symmetric(
                                              vertical: 10,
                                            ),
                                          ),
                                          onPressed: busyAction
                                              ? null
                                              : () => _cancelLearnerFromSlot(
                                                  slot,
                                                  p.uid,
                                                  sheetContext,
                                                ),
                                          icon: const Icon(Icons.close_rounded),
                                          label: const Text(
                                            'Cancel',
                                            style: TextStyle(
                                              fontWeight: FontWeight.w900,
                                            ),
                                          ),
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
              ],
            ),
          ),
        );
      },
    );
  }

  // ========================= UI =========================

  @override
  Widget build(BuildContext context) {
    final course = _selectedCourse();
    final filtered = _filteredSlots();

    final teacherMap = <String, String>{};
    for (final s in bookedSlots) {
      teacherMap[s.teacherId] = s.teacherName;
    }
    final teacherIds = teacherMap.keys.toList()
      ..sort((a, b) => (teacherMap[a] ?? '').compareTo(teacherMap[b] ?? ''));

    final totalLearners = filtered.fold<int>(
      0,
      (sum, s) => sum + s.learnerCount,
    );
    final futureCount = filtered
        .where((s) => s.start.isAfter(DateTime.now()))
        .length;

    return Scaffold(
      backgroundColor: appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: primaryBlue),
        title: const Text(
          'Admin Booking',
          style: TextStyle(color: primaryBlue, fontWeight: FontWeight.w900),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed:
                (loadingCourses || loadingBookings || selectedCourseId == null)
                ? null
                : () => _loadBookingsForCourse(selectedCourseId!),
            icon: const Icon(Icons.refresh_rounded, color: primaryBlue),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: loadingCourses
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 14),
              children: [
                _Card(
                  title: course?.title ?? 'Select a course',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildCompactSelectors(),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _StatPill(
                            label: 'Rows',
                            value: '${filtered.length}',
                            icon: Icons.table_rows_rounded,
                          ),
                          _StatPill(
                            label: 'Lrnrs',
                            value: '$totalLearners',
                            icon: Icons.people_alt_rounded,
                          ),
                          _StatPill(
                            label: 'Up',
                            value: '$futureCount',
                            icon: Icons.schedule_rounded,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                _Card(
                  title: 'Filters',
                  child: Column(
                    children: [
                      TextField(
                        controller: searchC,
                        decoration: InputDecoration(
                          hintText:
                              'Search teacher / date / time / session / status',
                          isDense: true,
                          prefixIcon: const Icon(Icons.search_rounded),
                          suffixIcon: searchC.text.trim().isEmpty
                              ? null
                              : IconButton(
                                  onPressed: () => searchC.clear(),
                                  icon: const Icon(Icons.close_rounded),
                                ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: uiBorder),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _smallDropdown(
                            width: 160,
                            value: teacherFilter,
                            items: [
                              const DropdownMenuItem(
                                value: 'all',
                                child: Text('All teachers'),
                              ),
                              ...teacherIds.map(
                                (id) => DropdownMenuItem(
                                  value: id,
                                  child: Text(
                                    teacherMap[id] ?? 'Teacher',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                            ],
                            onChanged: (v) {
                              if (v == null) return;
                              setState(() => teacherFilter = v);
                            },
                          ),
                          _smallDropdown(
                            width: 130,
                            value: dateFilter,
                            items: const [
                              DropdownMenuItem(
                                value: 'all',
                                child: Text('All'),
                              ),
                              DropdownMenuItem(
                                value: 'today',
                                child: Text('Today'),
                              ),
                              DropdownMenuItem(
                                value: 'thisWeek',
                                child: Text('This week'),
                              ),
                              DropdownMenuItem(
                                value: 'future',
                                child: Text('Upcoming'),
                              ),
                            ],
                            onChanged: (v) {
                              if (v == null) return;
                              setState(() => dateFilter = v);
                            },
                          ),
                          _togglePill(
                            label: 'Group only',
                            value: onlyMultiLearner,
                            onChanged: (v) =>
                                setState(() => onlyMultiLearner = v),
                          ),
                          OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: primaryBlue,
                              side: BorderSide(
                                color: primaryBlue.withValues(alpha: 0.20),
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(999),
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                            ),
                            onPressed: _clearFilters,
                            icon: const Icon(
                              Icons.filter_alt_off_rounded,
                              size: 18,
                            ),
                            label: const Text(
                              'Clear',
                              style: TextStyle(fontWeight: FontWeight.w800),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                _Card(
                  title: 'All bookings',
                  child: loadingBookings
                      ? const Padding(
                          padding: EdgeInsets.symmetric(vertical: 24),
                          child: Center(child: CircularProgressIndicator()),
                        )
                      : filtered.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: Text(
                            'No bookings found for this course.',
                            style: TextStyle(fontWeight: FontWeight.w800),
                          ),
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${filtered.length} row${filtered.length == 1 ? '' : 's'}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w900,
                                color: primaryBlue,
                              ),
                            ),
                            const SizedBox(height: 8),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: DataTable(
                                  horizontalMargin: 10,
                                  columnSpacing: 14,
                                  headingRowHeight: 38,
                                  dataRowMinHeight: 48,
                                  dataRowMaxHeight: 56,
                                  columns: const [
                                    DataColumn(label: Text('Day')),
                                    DataColumn(label: Text('Time')),
                                    DataColumn(label: Text('Teacher')),
                                    DataColumn(label: Text('Sess')),
                                    DataColumn(label: Text('Lrnrs')),
                                    DataColumn(label: Text('Status')),
                                    DataColumn(label: Text('Act')),
                                  ],
                                  rows: filtered.map((s) {
                                    final statusColor = _statusColorForSlot(s);
                                    final isPast = s.start.isBefore(
                                      DateTime.now(),
                                    );

                                    return DataRow(
                                      cells: [
                                        DataCell(
                                          Text(
                                            _friendlyDate(s.start),
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w800,
                                              fontSize: 12,
                                            ),
                                          ),
                                        ),
                                        DataCell(
                                          Text(
                                            s.time,
                                            style: TextStyle(
                                              fontWeight: FontWeight.w900,
                                              fontSize: 12,
                                              color: isPast
                                                  ? Colors.grey.shade700
                                                  : actionOrange,
                                            ),
                                          ),
                                        ),
                                        DataCell(
                                          ConstrainedBox(
                                            constraints: const BoxConstraints(
                                              maxWidth: 110,
                                            ),
                                            child: Text(
                                              s.teacherName,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontWeight: FontWeight.w700,
                                                fontSize: 12,
                                              ),
                                            ),
                                          ),
                                        ),
                                        DataCell(
                                          Text(
                                            s.sessionNo <= 0
                                                ? '—'
                                                : '${s.sessionNo}',
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w800,
                                              fontSize: 12,
                                            ),
                                          ),
                                        ),
                                        DataCell(
                                          Text(
                                            '${s.learnerCount}',
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w900,
                                              fontSize: 12,
                                            ),
                                          ),
                                        ),
                                        DataCell(
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 7,
                                              vertical: 4,
                                            ),
                                            decoration: BoxDecoration(
                                              color: statusColor.withValues(alpha: 
                                                0.10,
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(999),
                                            ),
                                            child: Text(
                                              _statusLabelForSlot(s),
                                              style: TextStyle(
                                                fontWeight: FontWeight.w900,
                                                color: statusColor,
                                                fontSize: 11,
                                              ),
                                            ),
                                          ),
                                        ),
                                        DataCell(
                                          TextButton(
                                            onPressed: () =>
                                                _openSlotDetails(s),
                                            style: TextButton.styleFrom(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 8,
                                                    vertical: 6,
                                                  ),
                                              minimumSize: Size.zero,
                                              tapTargetSize:
                                                  MaterialTapTargetSize
                                                      .shrinkWrap,
                                            ),
                                            child: const Text(
                                              'View',
                                              style: TextStyle(
                                                fontWeight: FontWeight.w900,
                                                fontSize: 12,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    );
                                  }).toList(),
                                ),
                              ),
                            ),
                          ],
                        ),
                ),
              ],
            ),
    );
  }

  Widget _buildCompactSelectors() {
    final levels = _levelOptionsWithBookingsOnly();
    final filteredCourses = _coursesForSelectedLevel();

    String? safeCourseId = selectedCourseId;
    if (safeCourseId != null &&
        !filteredCourses.any((c) => c.id == safeCourseId)) {
      safeCourseId = filteredCourses.isNotEmpty
          ? filteredCourses.first.id
          : null;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (levels.isNotEmpty)
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _chip('All levels', levelFilter == 'all', () async {
                setState(() {
                  levelFilter = 'all';
                  if (!_coursesForSelectedLevel().any(
                    (c) => c.id == selectedCourseId,
                  )) {
                    selectedCourseId = _coursesForSelectedLevel().isNotEmpty
                        ? _coursesForSelectedLevel().first.id
                        : null;
                  }
                });
                if (selectedCourseId != null) {
                  await _loadBookingsForCourse(selectedCourseId!);
                }
              }),
              ...levels.map(
                (lvl) => _chip(lvl, levelFilter == lvl, () async {
                  final matching = allCourses
                      .where((c) => c.levelText == lvl)
                      .toList();

                  setState(() {
                    levelFilter = lvl;
                    if (!matching.any((c) => c.id == selectedCourseId)) {
                      selectedCourseId = matching.isNotEmpty
                          ? matching.first.id
                          : null;
                    }
                  });

                  if (selectedCourseId != null) {
                    await _loadBookingsForCourse(selectedCourseId!);
                  } else {
                    setState(() => bookedSlots = []);
                  }
                }),
              ),
            ],
          ),
        if (levels.isNotEmpty) const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              flex: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: uiBorder),
                ),
                child: DropdownButton<String>(
                  value: safeCourseId,
                  isExpanded: true,
                  underline: const SizedBox.shrink(),
                  icon: const Icon(
                    Icons.expand_more_rounded,
                    color: primaryBlue,
                  ),
                  hint: const Text('No course'),
                  items: filteredCourses
                      .map(
                        (c) => DropdownMenuItem(
                          value: c.id,
                          child: Text(
                            _shortCourseLabel(c),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w900,
                              color: primaryBlue,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: filteredCourses.isEmpty
                      ? null
                      : (v) async {
                          if (v == null) return;
                          setState(() {
                            selectedCourseId = v;
                            bookedSlots = [];
                            teacherFilter = 'all';
                          });
                          await _loadBookingsForCourse(v);
                        },
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
        ),
      ],
    );
  }

  Widget _smallDropdown({
    required double width,
    required String value,
    required List<DropdownMenuItem<String>> items,
    required ValueChanged<String?> onChanged,
  }) {
    return Container(
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: uiBorder),
      ),
      child: DropdownButton<String>(
        value: value,
        isExpanded: true,
        underline: const SizedBox.shrink(),
        icon: const Icon(Icons.expand_more_rounded, color: primaryBlue),
        items: items,
        onChanged: onChanged,
      ),
    );
  }

  Widget _chip(String label, bool on, VoidCallback tap) {
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: tap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: on ? actionOrange.withValues(alpha: 0.12) : Colors.white,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: on ? actionOrange.withValues(alpha: 0.35) : uiBorder,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontWeight: FontWeight.w900,
            color: on ? actionOrange : primaryBlue,
            fontSize: 11.5,
          ),
        ),
      ),
    );
  }

  Widget _togglePill({
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: uiBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontWeight: FontWeight.w900,
              color: primaryBlue,
              fontSize: 11.5,
            ),
          ),
          const SizedBox(width: 6),
          Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: actionOrange,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ],
      ),
    );
  }
}

// ========================= Models =========================

class _CourseItem {
  final String id;
  final String title;
  final String levelText;
  final String category;
  final int orderIndex;

  _CourseItem({
    required this.id,
    required this.title,
    required this.levelText,
    required this.category,
    required this.orderIndex,
  });
}

class _AdminBookedSlot {
  final String courseId;
  final String dayKey;
  final String time;
  final DateTime start;
  final String teacherId;
  final String teacherName;
  final int sessionNo;
  final List<String> learnerUids;
  final int createdAt;

  _AdminBookedSlot({
    required this.courseId,
    required this.dayKey,
    required this.time,
    required this.start,
    required this.teacherId,
    required this.teacherName,
    required this.sessionNo,
    required this.learnerUids,
    required this.createdAt,
  });

  int get learnerCount => learnerUids.length;
}

class _LearnerProfile {
  final String uid;
  final String fullName;
  final String serial;
  final String email;
  final String phone;
  final String status;

  _LearnerProfile({
    required this.uid,
    required this.fullName,
    required this.serial,
    required this.email,
    required this.phone,
    required this.status,
  });
}

class _ReservationSummary {
  final int bookedCount;
  final int? groupSessionNo;

  _ReservationSummary({
    required this.bookedCount,
    required this.groupSessionNo,
  });
}

class _AvailSlot {
  final String courseId;
  final String dayKey;
  final String time;
  final DateTime start;
  final String teacherId;
  final String teacherName;
  final int bookedCount;
  final int? groupSessionNo;
  final int maxLearnersPerSlot;

  _AvailSlot({
    required this.courseId,
    required this.dayKey,
    required this.time,
    required this.start,
    required this.teacherId,
    required this.teacherName,
    required this.bookedCount,
    required this.groupSessionNo,
    required this.maxLearnersPerSlot,
  });

  bool get isFull {
    final cap = maxLearnersPerSlot <= 0 ? 6 : maxLearnersPerSlot;
    return bookedCount >= cap;
  }
}

// ========================= Small UI Widgets =========================

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.child});

  final String title;
  final Widget child;

  static const primaryBlue = Color(0xFF1A2B48);
  static const uiBorder = Color(0xFFD1D9E0);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: uiBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontWeight: FontWeight.w900,
              color: primaryBlue,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

class _StatPill extends StatelessWidget {
  const _StatPill({
    required this.label,
    required this.value,
    required this.icon,
  });

  final String label;
  final String value;
  final IconData icon;

  static const primaryBlue = Color(0xFF1A2B48);
  static const uiBorder = Color(0xFFD1D9E0);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: uiBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: primaryBlue),
          const SizedBox(width: 6),
          Text(
            '$label: ',
            style: const TextStyle(
              fontWeight: FontWeight.w800,
              color: primaryBlue,
              fontSize: 12,
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              fontWeight: FontWeight.w900,
              color: primaryBlue,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}
