import 'dart:async';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import '../services/booking_communication_service.dart';
import '../shared/app_feedback.dart';
import '../shared/admin_web_layout.dart';

class AdminBookingScreen extends StatefulWidget {
  const AdminBookingScreen({super.key});

  @override
  State<AdminBookingScreen> createState() => _AdminBookingScreenState();
}

class _AdminBookingScreenState extends State<AdminBookingScreen> {
  // ===== Colors =====
  static const primaryBlue = Color(0xFF0E7C86);
  static const actionOrange = Color(0xFFBF5D39);
  static const appBg = Color(0xFFFAFCFF);
  static const uiBorder = Color(0xFFD8CFC1);
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
  final ScrollController _bookingRowsMain = ScrollController();
  final ScrollController _bookingRowsFrozen = ScrollController();
  bool _syncingBookingRows = false;

  @override
  void initState() {
    super.initState();
    _loadCourses();
    _bookingRowsMain.addListener(() {
      if (_syncingBookingRows || !_bookingRowsFrozen.hasClients) return;
      _syncingBookingRows = true;
      _bookingRowsFrozen.jumpTo(
        _bookingRowsMain.offset.clamp(
          _bookingRowsFrozen.position.minScrollExtent,
          _bookingRowsFrozen.position.maxScrollExtent,
        ),
      );
      _syncingBookingRows = false;
    });
    _bookingRowsFrozen.addListener(() {
      if (_syncingBookingRows || !_bookingRowsMain.hasClients) return;
      _syncingBookingRows = true;
      _bookingRowsMain.jumpTo(
        _bookingRowsFrozen.offset.clamp(
          _bookingRowsMain.position.minScrollExtent,
          _bookingRowsMain.position.maxScrollExtent,
        ),
      );
      _syncingBookingRows = false;
    });
    searchC.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    searchC.dispose();
    _bookingRowsMain.dispose();
    _bookingRowsFrozen.dispose();
    super.dispose();
  }

  // ========================= Helpers =========================

  void _toast(String msg) {
    if (!mounted) return;
    AppToast.fromSnackBar(
      context,
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

      if (y == null || m == null || d == null || hh == null || mm == null) {
        return null;
      }

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
  DatabaseReference _reservationByTeacherRef(
    String cid,
    String dayKey,
    String hhmm,
    String teacherId,
  ) => _db.child('booking_reservations/$cid/$dayKey/$hhmm/$teacherId');

  _CourseItem? _selectedCourse() {
    final cid = selectedCourseId;
    if (cid == null) return null;
    for (final c in allCourses) {
      if (c.id == cid) return c;
    }
    return null;
  }

  _CourseItem? _courseById(String courseId) {
    for (final c in allCourses) {
      if (c.id == courseId) return c;
    }
    return null;
  }

  String _courseTitle(String courseId) {
    return _courseById(courseId)?.title ?? courseId;
  }

  String _shortCourseLabel(_CourseItem c) {
    final parts = <String>[];
    if (c.levelText.isNotEmpty) parts.add(c.levelText);
    if (c.category.isNotEmpty) parts.add(c.category);
    if (parts.isEmpty) return c.title;
    return '${parts.join(' • ')} • ${c.title}';
  }

  String _statusLabelForSlot(_AdminBookedSlot s) {
    if (_isLiveBooking(s)) return 'Live';
    if (s.start.isBefore(DateTime.now())) return 'Past';
    if (s.learnerCount >= 6) return 'Full';
    if (s.learnerCount >= 2) return 'Group';
    return 'Open';
  }

  String _sessionLabel(int sessionNo) {
    return sessionNo <= 0 ? 'Session —' : 'Session $sessionNo';
  }

  String _sessionFieldText(String value, String fallback) {
    final text = value.trim();
    return text.isEmpty ? fallback : text;
  }

  double _sheetActionButtonWidth(double maxWidth) {
    if (maxWidth <= 440) return maxWidth;
    if (maxWidth <= 760) return (maxWidth - 8) / 2;
    return 220;
  }

  bool _isPastBooking(_AdminBookedSlot slot) {
    return slot.start.isBefore(DateTime.now());
  }

  bool _isLiveBooking(_AdminBookedSlot slot) {
    final now = DateTime.now();
    final openFrom = slot.start.subtract(const Duration(minutes: 10));
    final dur = slot.durationMinutes <= 0 ? 60 : slot.durationMinutes;
    final openUntil = slot.start
        .add(Duration(minutes: dur))
        .add(const Duration(minutes: 15));
    return now.isAfter(openFrom) && now.isBefore(openUntil);
  }

  String _bookingKey(String courseId, String dayKey, String hhmm) =>
      '$courseId|$dayKey|$hhmm';

  Color _statusColorForSlot(_AdminBookedSlot s) {
    if (_isLiveBooking(s)) return const Color(0xFF0B7285);
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

                for (final teacherEntry in m.entries) {
                  final teacherSlot = teacherEntry.value;
                  if (teacherSlot is! Map) continue;
                  final tm = teacherSlot.map(
                    (k, vv) => MapEntry(k.toString(), vv),
                  );
                  final tLearners = tm['learners'];
                  if (tLearners is Map && tLearners.isNotEmpty) {
                    found = true;
                    break;
                  }
                }
                if (found) break;
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
        if (a.orderIndex != b.orderIndex) {
          return a.orderIndex.compareTo(b.orderIndex);
        }
        return a.title.compareTo(b.title);
      });

      String? nextSelected = selectedCourseId;
      if (nextSelected != null && !out.any((c) => c.id == nextSelected)) {
        nextSelected = null;
      }

      setState(() {
        allCourses = out;
        courseHasBookings = hasBookings;
        selectedCourseId = nextSelected;
      });

      await _loadAllBookedSlots();
    } catch (e) {
      _toast('Failed loading courses: $e');
    } finally {
      if (mounted) {
        setState(() => loadingCourses = false);
      }
    }
  }

  // ========================= Load Bookings =========================

  Future<void> _loadAllBookedSlots() async {
    setState(() {
      loadingBookings = true;
      bookedSlots = [];
      teacherFilter = 'all';
    });

    try {
      final snap = await _db.child('booking_reservations').get();
      final v = snap.value;

      final List<_AdminBookedSlot> out = [];

      if (v is Map) {
        final byCourse = v.map((k, vv) => MapEntry(k.toString(), vv));

        for (final courseEntry in byCourse.entries) {
          final cid = courseEntry.key;
          final courseNode = courseEntry.value;
          if (courseNode is! Map) continue;

          final days = courseNode.map((k, vv) => MapEntry(k.toString(), vv));

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
              final start = _parseSlotStart(dayKey, hhmm);
              if (start == null) continue;

              void collect(Map<dynamic, dynamic> slotNode, String teacherKey) {
                final learnersRaw = slotNode['learners'];
                if (learnersRaw is! Map) return;
                final learnersMap = learnersRaw.map(
                  (k, vv) => MapEntry(k.toString(), vv),
                );
                final learnerUids = learnersMap.keys
                    .map((e) => e.toString())
                    .toList();
                if (learnerUids.isEmpty) return;

                out.add(
                  _AdminBookedSlot(
                    courseId: cid,
                    dayKey: dayKey,
                    time: hhmm,
                    start: start,
                    teacherId: (slotNode['teacherId'] ?? teacherKey)
                        .toString()
                        .trim(),
                    teacherName: (slotNode['teacherName'] ?? 'Teacher')
                        .toString()
                        .trim(),
                    durationMinutes: _toInt(
                      slotNode['durationMinutes'] ?? slotNode['duration'],
                      fallback: 60,
                    ),
                    sessionNo: _toInt(slotNode['sessionNo'], fallback: 0),
                    learnerUids: learnerUids,
                    createdAt: _toInt(slotNode['createdAt'], fallback: 0),
                  ),
                );
              }

              if (m['learners'] is Map) {
                collect(m, '');
                continue;
              }

              for (final teacherEntry in m.entries) {
                final teacherNode = teacherEntry.value;
                if (teacherNode is! Map) continue;
                collect(
                  teacherNode.map((k, vv) => MapEntry(k.toString(), vv)),
                  teacherEntry.key.toString(),
                );
              }
            }
          }
        }
      }

      final now = DateTime.now();
      out.sort((a, b) {
        final aPast = a.start.isBefore(now) ? 1 : 0;
        final bPast = b.start.isBefore(now) ? 1 : 0;
        if (aPast != bPast) return aPast.compareTo(bPast);
        return a.start.compareTo(b.start);
      });

      if (!mounted) return;
      setState(() => bookedSlots = out);
    } catch (e) {
      _toast('Failed loading bookings: $e');
    } finally {
      if (mounted) {
        setState(() => loadingBookings = false);
      }
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

  String _actingAdminUid() {
    return (FirebaseAuth.instance.currentUser?.uid ?? '').trim();
  }

  String _actingAdminName() {
    return (FirebaseAuth.instance.currentUser?.email ?? 'Admin').trim();
  }

  List<String> _learnerNamesFor(Iterable<String> uids) {
    return uids
        .map((uid) => learnerCache[uid]?.fullName.trim() ?? '')
        .map((name) => name.isEmpty ? 'Learner' : name)
        .toList(growable: false);
  }

  List<BookingRecipient> _learnerRecipientsFor(Iterable<String> uids) {
    return uids
        .map(
          (uid) => BookingRecipient(
            uid: uid,
            name: learnerCache[uid]?.fullName.trim() ?? 'Learner',
            role: 'learner',
          ),
        )
        .toList(growable: false);
  }

  BookingSnapshot _bookingSnapshot({
    required String courseId,
    required String dayKey,
    required String time,
    required int sessionNo,
    required String teacherId,
    required String teacherName,
    required List<String> learnerUids,
  }) {
    return BookingSnapshot(
      courseId: courseId,
      courseTitle: _courseTitle(courseId),
      dayKey: dayKey,
      time: time,
      sessionNo: sessionNo,
      teacherId: teacherId,
      teacherName: teacherName,
      learnerUids: learnerUids,
      learnerNames: _learnerNamesFor(learnerUids),
    );
  }

  Future<void> _dispatchBookingChange({
    required BookingChangeAction action,
    required BookingSnapshot before,
    BookingSnapshot? after,
    required List<String> learnerUids,
    String? cancelReason,
    String? rescheduleReason,
  }) async {
    await _ensureLearnerProfiles(learnerUids);

    final actingAdminUid = _actingAdminUid();
    if (actingAdminUid.isEmpty) {
      throw Exception('Missing admin account for booking communication.');
    }

    await BookingCommunicationService.sendBookingChangeCommunications(
      request: BookingCommunicationRequest(
        action: action,
        actingAdminUid: actingAdminUid,
        actingAdminName: _actingAdminName(),
        before: before,
        after: after,
        learnerRecipients: _learnerRecipientsFor(learnerUids),
        cancelReason: cancelReason,
        rescheduleReason: rescheduleReason,
      ),
    );
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

    final out = <_AdminBookedSlot>[];

    for (final s in bookedSlots) {
      if (selectedCourseId != null && s.courseId != selectedCourseId) continue;
      if (teacherFilter != 'all' && s.teacherId != teacherFilter) continue;
      if (onlyMultiLearner && s.learnerCount < 2) continue;

      if (dateFilter == 'today' && !_sameDay(s.start, today)) continue;
      if (dateFilter == 'thisWeek' && !_isThisWeek(s.start)) continue;
      if (dateFilter == 'future' && !s.start.isAfter(now)) continue;

      if (levelFilter != 'all') {
        final c = _courseById(s.courseId);
        if (c == null || c.levelText != levelFilter) continue;
      }

      if (q.isNotEmpty) {
        final haystack = [
          s.teacherName,
          s.teacherId,
          _courseTitle(s.courseId),
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
    if (_isPastBooking(slot) && !_isLiveBooking(slot)) {
      _toast('Past booking locked. Admin changes are disabled.');
      return;
    }

    final isLive = _isLiveBooking(slot);
    final reason = isLive ? await _pickCancelReason() : null;
    if (isLive && reason == null) return;

    if (!isLive) {
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
    }

    setState(() => busyAction = true);

    try {
      Future<_AdminCancelStatus> cancelAtRef(DatabaseReference ref) async {
        const maxAttempts = 2;

        for (int attempt = 0; attempt < maxAttempts; attempt++) {
          try {
            final result = await ref.runTransaction((Object? currentData) {
              if (currentData is! Map) return Transaction.abort();

              final node = currentData.map((k, v) => MapEntry(k.toString(), v));
              final learnersRaw = node['learners'];
              if (learnersRaw is! Map) return Transaction.abort();

              final learners = learnersRaw.map(
                (k, v) => MapEntry(k.toString(), v),
              );
              if (!learners.containsKey(learnerUid)) return Transaction.abort();

              learners.remove(learnerUid);

              if (learners.isEmpty) {
                return Transaction.success(null);
              }

              node['learners'] = learners;
              return Transaction.success(node);
            });

            if (result.committed) {
              return _AdminCancelStatus.cancelled;
            }

            final snap = await ref.get();
            if (!snap.exists || snap.value == null) {
              return _AdminCancelStatus.notFound;
            }

            if (snap.value is! Map) {
              if (attempt < maxAttempts - 1) {
                await Future.delayed(const Duration(milliseconds: 250));
                continue;
              }
              return _AdminCancelStatus.failed;
            }

            final node = (snap.value as Map).map(
              (k, v) => MapEntry(k.toString(), v),
            );
            final learnersRaw = node['learners'];

            if (learnersRaw is Map) {
              final learners = learnersRaw.map(
                (k, v) => MapEntry(k.toString(), v),
              );
              if (!learners.containsKey(learnerUid)) {
                return _AdminCancelStatus.notFound;
              }
            } else {
              final hasNestedLearners = node.values.any((v) {
                if (v is! Map) return false;
                final vm = v.map((k, vv) => MapEntry(k.toString(), vv));
                return vm['learners'] is Map;
              });
              if (hasNestedLearners) {
                return _AdminCancelStatus.notFound;
              }
            }

            if (attempt < maxAttempts - 1) {
              await Future.delayed(const Duration(milliseconds: 250));
              continue;
            }

            return _AdminCancelStatus.failed;
          } catch (_) {
            if (attempt < maxAttempts - 1) {
              await Future.delayed(const Duration(milliseconds: 250));
              continue;
            }
            return _AdminCancelStatus.failed;
          }
        }

        return _AdminCancelStatus.failed;
      }

      final nestedRef = _reservationByTeacherRef(
        slot.courseId,
        slot.dayKey,
        slot.time,
        slot.teacherId,
      );
      final nestedStatus = await cancelAtRef(nestedRef);
      final legacyStatus = nestedStatus == _AdminCancelStatus.cancelled
          ? _AdminCancelStatus.cancelled
          : await cancelAtRef(
              _reservationsRef(slot.courseId, slot.dayKey, slot.time),
            );

      final finalStatus = nestedStatus == _AdminCancelStatus.cancelled
          ? nestedStatus
          : legacyStatus;

      if (finalStatus == _AdminCancelStatus.failed) {
        _toast('Cancel failed. Please try again.');
        return;
      }

      if (finalStatus == _AdminCancelStatus.notFound) {
        _toast('This booking was already canceled. ✅');
      } else {
        _toast('Booking canceled ✅');
        try {
          await _dispatchBookingChange(
            action: isLive
                ? BookingChangeAction.cancelGroupLive
                : BookingChangeAction.cancelLearner,
            before: _bookingSnapshot(
              courseId: slot.courseId,
              dayKey: slot.dayKey,
              time: slot.time,
              sessionNo: slot.sessionNo,
              teacherId: slot.teacherId,
              teacherName: slot.teacherName,
              learnerUids: [learnerUid],
            ),
            learnerUids: [learnerUid],
            cancelReason: reason,
          );
        } catch (e) {
          _toast('Booking canceled, but notifications failed.');
        }
      }

      if (!mounted) return;
      if (detailsSheetContext.mounted &&
          Navigator.of(detailsSheetContext).canPop()) {
        Navigator.of(detailsSheetContext).pop();
      }

      if (mounted) {
        setState(() => busyAction = false);
      }

      await _loadAllBookedSlots();
    } catch (e) {
      _toast('Cancel failed: $e');
    } finally {
      if (mounted) {
        setState(() => busyAction = false);
      }
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

            void saveSummary(
              Map<dynamic, dynamic> slotNode,
              String teacherKey,
            ) {
              final learnersRaw = slotNode['learners'];
              int count = 0;
              if (learnersRaw is Map) count = learnersRaw.length;
              if (count <= 0) return;

              final teacherId = (slotNode['teacherId'] ?? teacherKey)
                  .toString()
                  .trim();
              if (teacherId.isEmpty) return;

              final key = '${dayEntry.key}|${timeEntry.key}|$teacherId';
              final sessionNo = _toInt(slotNode['sessionNo'], fallback: 0);

              summaries[key] = _ReservationSummary(
                bookedCount: count,
                groupSessionNo: sessionNo > 0 ? sessionNo : null,
              );
            }

            if (m['learners'] is Map) {
              saveSummary(m, '');
            } else {
              for (final teacherEntry in m.entries) {
                final teacherNode = teacherEntry.value;
                if (teacherNode is! Map) continue;
                saveSummary(
                  teacherNode.map((k, vv) => MapEntry(k.toString(), vv)),
                  teacherEntry.key.toString(),
                );
              }
            }
          }
        }
      }

      final availabilitySnap = await _db.child('booking_availability').get();
      if (!availabilitySnap.exists || availabilitySnap.value is! Map) {
        return out;
      }

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

            final key = '$dayKey|$hhmm|$teacherId';
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

  Future<_CourseSyllabus> _loadCourseSessionChoices(
    String courseId,
  ) async {
    final cid = courseId.trim();
    if (cid.isEmpty) return const _CourseSyllabus(units: []);

    final units = <_SyllabusUnit>[];

    try {
      final flexibleSnap = await _db.child('syllabi/$cid/flexible').get();
      if (flexibleSnap.exists && flexibleSnap.value is Map) {
        final root = (flexibleSnap.value as Map).map(
          (k, v) => MapEntry(k.toString(), v),
        );

        int globalNo = 1;
        final rawUnits = root['units'];
        if (rawUnits is List) {
          for (final unitRaw in rawUnits) {
            if (unitRaw is! Map) continue;
            final unit = unitRaw.map((k, v) => MapEntry(k.toString(), v));
            final rawSessions = unit['sessions'];
            if (rawSessions is! List) continue;

            final unitSessions = <_SessionChoiceInfo>[];
            for (final sessionRaw in rawSessions) {
              if (sessionRaw is! Map) continue;
              final session = sessionRaw.map(
                (k, v) => MapEntry(k.toString(), v),
              );
              unitSessions.add(_SessionChoiceInfo(
                sessionNo: globalNo,
                title: (session['sessionTitle'] ?? session['title'] ?? '')
                    .toString()
                    .trim(),
                skillType: (session['skillType'] ?? '').toString().trim(),
                objective: (session['objective'] ?? '').toString().trim(),
              ));
              globalNo += 1;
            }

            if (unitSessions.isNotEmpty) {
              units.add(_SyllabusUnit(
                id: (unit['id'] ?? '').toString(),
                title: (unit['title'] ?? 'Unit').toString(),
                description: (unit['description'] ?? '').toString().trim(),
                order: _toInt(unit['order'], fallback: 0),
                sessions: unitSessions,
              ));
            }
          }
        }
      }

      // booking_curriculum extras (sessions not in flexible syllabus)
      final curricSnap =
          await _db.child('booking_curriculum/$cid/sessions').get();
      if (curricSnap.exists && curricSnap.value is Map) {
        final root = (curricSnap.value as Map).map(
          (k, v) => MapEntry(k.toString(), v),
        );
        final existingNos = <int>{};
        for (final u in units) {
          for (final s in u.sessions) {
            existingNos.add(s.sessionNo);
          }
        }
        final extra = <_SessionChoiceInfo>[];
        for (final entry in root.entries) {
          final keyNo = int.tryParse(entry.key.toString()) ?? 0;
          final raw = entry.value;
          if (raw is! Map) continue;
          final m = raw.map((k, v) => MapEntry(k.toString(), v));
          int no = _toInt(m['sessionNo'], fallback: 0);
          if (no <= 0) no = _toInt(m['sessionNumber'], fallback: 0);
          if (no <= 0) no = _toInt(m['order'], fallback: 0);
          if (no <= 0) no = keyNo;
          if (no <= 0 || existingNos.contains(no)) continue;
          extra.add(_SessionChoiceInfo(
            sessionNo: no,
            title: (m['sessionTitle'] ?? m['title'] ?? '').toString().trim(),
            skillType: (m['skillType'] ?? '').toString().trim(),
            objective: (m['objective'] ?? '').toString().trim(),
          ));
        }
        if (extra.isNotEmpty) {
          extra.sort((a, b) => a.sessionNo.compareTo(b.sessionNo));
          units.add(_SyllabusUnit(
            id: '',
            title: 'Other sessions',
            sessions: extra,
            order: 9999,
          ));
        }
      }
    } catch (_) {}

    units.sort((a, b) => a.order.compareTo(b.order));
    return _CourseSyllabus(units: units);
  }

  List<_SessionChoiceInfo> _ensureSessionChoiceIncluded(
    List<_SessionChoiceInfo> choices,
    int sessionNo,
  ) {
    if (sessionNo <= 0) return choices;
    if (choices.any((choice) => choice.sessionNo == sessionNo)) {
      return choices;
    }
    final next = [...choices, _SessionChoiceInfo(sessionNo: sessionNo)]
      ..sort((a, b) => a.sessionNo.compareTo(b.sessionNo));
    return next;
  }

  Future<int?> _showSessionChoiceSheet({
    required String courseId,
    required String title,
    required String description,
    required _CourseSyllabus syllabus,
    required int selectedSessionNo,
    String? helperText,
  }) async {
    final flat = syllabus.allChoices;
    if (flat.isEmpty) return null;

    int selectedNo = flat.any((s) => s.sessionNo == selectedSessionNo)
        ? selectedSessionNo
        : flat.first.sessionNo;

    final chosen = await showModalBottomSheet<int>(
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
            final maxSheetHeight = MediaQuery.of(context).size.height * 0.88;
            return SafeArea(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxSheetHeight),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: const TextStyle(
                              fontWeight: FontWeight.w900,
                              fontSize: 15,
                              color: primaryBlue,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            description,
                            style: TextStyle(
                              color: Colors.grey.shade700,
                              fontWeight: FontWeight.w600,
                              height: 1.35,
                            ),
                          ),
                          if (helperText != null) ...[
                            const SizedBox(height: 6),
                            Text(
                              helperText,
                              style: TextStyle(
                                color: actionOrange,
                                fontWeight: FontWeight.w700,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        children: [
                          for (final unit in syllabus.units) ...[
                            if (unit.title.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 7,
                                  ),
                                  decoration: BoxDecoration(
                                    color: primaryBlue.withValues(alpha: 0.08),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    unit.title,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w900,
                                      color: primaryBlue,
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                              ),
                            ...unit.sessions.map((session) {
                              final isSelected =
                                  session.sessionNo == selectedNo;
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 3),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(8),
                                  onTap: () =>
                                      setInner(() => selectedNo = session.sessionNo),
                                  child: AnimatedContainer(
                                    duration:
                                        const Duration(milliseconds: 150),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 10,
                                    ),
                                    decoration: BoxDecoration(
                                      color: isSelected
                                          ? actionOrange.withValues(alpha: 0.10)
                                          : Colors.white,
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: isSelected
                                            ? actionOrange
                                                .withValues(alpha: 0.50)
                                            : uiBorder.withValues(alpha: 0.30),
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        Container(
                                          width: 22,
                                          height: 22,
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            color: isSelected
                                                ? actionOrange
                                                : Colors.white,
                                            border: Border.all(
                                              color: isSelected
                                                  ? actionOrange
                                                  : uiBorder,
                                              width: 2,
                                            ),
                                          ),
                                          child: isSelected
                                              ? const Icon(
                                                  Icons.check,
                                                  size: 14,
                                                  color: Colors.white,
                                                )
                                              : null,
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Text(
                                            'S${session.sessionNo}  ${session.title.isNotEmpty ? session.title : 'No title'}',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontWeight: FontWeight.w800,
                                              fontSize: 13,
                                              color: isSelected
                                                  ? actionOrange
                                                  : primaryBlue,
                                            ),
                                          ),
                                        ),
                                        if (session.objective.isNotEmpty ||
                                            session.skillType.isNotEmpty)
                                          SizedBox(
                                            height: 26,
                                            child: TextButton.icon(
                                              onPressed: () {
                                                _showSessionObjectiveSheet(
                                                  courseId: courseId,
                                                  sessionNo: session.sessionNo,
                                                );
                                              },
                                              style: TextButton.styleFrom(
                                                padding: const EdgeInsets.symmetric(
                                                  horizontal: 6,
                                                  vertical: 2,
                                                ),
                                                minimumSize: Size.zero,
                                                tapTargetSize:
                                                    MaterialTapTargetSize
                                                        .shrinkWrap,
                                                foregroundColor:
                                                    Colors.grey.shade500,
                                              ),
                                              icon: const Icon(
                                                Icons.info_outline_rounded,
                                                size: 14,
                                              ),
                                              label: const Text(
                                                '',
                                                style: TextStyle(
                                                  fontSize: 0,
                                                ),
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            }),
                            const SizedBox(height: 6),
                          ],
                        ],
                      ),
                    ),
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        14,
                        8,
                        14,
                        MediaQuery.of(context).padding.bottom + 16,
                      ),
                      child: SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: () =>
                              Navigator.pop(context, selectedNo),
                          icon: const Icon(Icons.check_rounded),
                          label: const Text(
                            'Continue',
                            style: TextStyle(fontWeight: FontWeight.w900),
                          ),
                        ),
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

    return chosen;
  }

  Future<void> _pickRescheduleTarget(
    _AdminBookedSlot sourceSlot,
    String learnerUid,
    BuildContext detailsSheetContext,
  ) async {
    final chosen = await _pickRescheduleChoice(sourceSlot);
    if (chosen == null) return;
    if (!detailsSheetContext.mounted) return;

    await _moveLearnerToNewSlot(
      sourceSlot: sourceSlot,
      learnerUid: learnerUid,
      target: chosen.slot,
      targetSessionNo: chosen.sessionNo,
      detailsSheetContext: detailsSheetContext,
    );
  }

  Future<_RescheduleChoice?> _pickRescheduleChoice(
    _AdminBookedSlot sourceSlot,
  ) async {
    if (_isPastBooking(sourceSlot)) {
      _toast('Past booking locked. Admin changes are disabled.');
      return null;
    }

    final available = await _buildAvailableSlotsForCourse(sourceSlot.courseId);
    var syllabus = await _loadCourseSessionChoices(sourceSlot.courseId);

    if (!mounted) return null;

    final basePossible = available.where((s) {
      if (s.dayKey == sourceSlot.dayKey &&
          s.time == sourceSlot.time &&
          s.teacherId == sourceSlot.teacherId) {
        return false;
      }
      if (s.start.isBefore(
        DateTime.now().subtract(const Duration(minutes: 1)),
      )) {
        return false;
      }
      if (s.isFull) return false;
      return true;
    }).toList();

    var choices = _ensureSessionChoiceIncluded(
      syllabus.allChoices,
      sourceSlot.sessionNo,
    );

    if (basePossible.isEmpty) {
      _toast('No valid target slots found.');
      return null;
    }

    String query = '';
    int selectedSessionNo = sourceSlot.sessionNo > 0
        ? sourceSlot.sessionNo
        : choices.first.sessionNo;

    return showModalBottomSheet<_RescheduleChoice>(
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
            final bySession = basePossible.where((s) {
              if (s.groupSessionNo == null) return true;
              return s.groupSessionNo == selectedSessionNo;
            }).toList();

            final filtered = bySession.where((s) {
              if (query.trim().isEmpty) return true;
              final q = query.trim().toLowerCase();
              final text =
                  '${s.teacherName} ${s.dayKey} ${s.time} ${_friendlyDateLong(s.start)} ${_sessionLabel(selectedSessionNo)}'
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
                    InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () async {
                        final picked = await _showSessionChoiceSheet(
                          courseId: sourceSlot.courseId,
                          title: 'Choose Session',
                          description:
                              'Swipe through the session cards, then keep the current session or choose another one before picking the new slot.',
                          syllabus: syllabus,
                          selectedSessionNo: selectedSessionNo,
                          helperText: selectedSessionNo == sourceSlot.sessionNo
                              ? 'Currently keeping the same session number.'
                              : 'Currently changing the session number during reschedule.',
                        );
                        if (picked == null) return;
                        setInner(() => selectedSessionNo = picked);
                      },
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: uiBorder),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Study session',
                              style: TextStyle(
                                color: Colors.grey.shade700,
                                fontWeight: FontWeight.w800,
                                fontSize: 12,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    _sessionLabel(selectedSessionNo),
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w900,
                                      color: primaryBlue,
                                      fontSize: 15,
                                    ),
                                  ),
                                ),
                                const Icon(
                                  Icons.swipe_rounded,
                                  color: actionOrange,
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              selectedSessionNo == sourceSlot.sessionNo
                                  ? 'Keeping the current session number. Tap to browse session cards.'
                                  : 'Changing the session number during reschedule. Tap to browse session cards.',
                              style: TextStyle(
                                color: Colors.grey.shade700,
                                fontWeight: FontWeight.w700,
                                fontSize: 12,
                                height: 1.3,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
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
                                  onTap: () => Navigator.pop(
                                    context,
                                    _RescheduleChoice(
                                      slot: s,
                                      sessionNo: selectedSessionNo,
                                    ),
                                  ),
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
                                              ? '${_sessionLabel(selectedSessionNo)} • Empty slot • Capacity ${s.bookedCount}/$cap'
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
  }

  Future<void> _moveLearnerToNewSlot({
    required _AdminBookedSlot sourceSlot,
    required String learnerUid,
    required _AvailSlot target,
    required int targetSessionNo,
    required BuildContext detailsSheetContext,
  }) async {
    if (busyAction) return;
    if (_isPastBooking(sourceSlot)) {
      _toast('Past booking locked. Admin changes are disabled.');
      return;
    }

    final rescheduleReason = await _pickRescheduleReason();
    if (rescheduleReason == null) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Reschedule booking'),
        content: Text(
          'Move this learner?\n\n'
          '${_sessionLabel(sourceSlot.sessionNo)} → ${_sessionLabel(targetSessionNo)}\n\n'
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
      final sourceRef = _reservationByTeacherRef(
        sourceSlot.courseId,
        sourceSlot.dayKey,
        sourceSlot.time,
        sourceSlot.teacherId,
      );
      final targetRef = _reservationByTeacherRef(
        target.courseId,
        target.dayKey,
        target.time,
        target.teacherId,
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
        if (existingSession > 0 && existingSession != targetSessionNo) {
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
        node['sessionNo'] = targetSessionNo;
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
        try {
          await _dispatchBookingChange(
            action: BookingChangeAction.rescheduleLearner,
            before: _bookingSnapshot(
              courseId: sourceSlot.courseId,
              dayKey: sourceSlot.dayKey,
              time: sourceSlot.time,
              sessionNo: sourceSlot.sessionNo,
              teacherId: sourceSlot.teacherId,
              teacherName: sourceSlot.teacherName,
              learnerUids: [learnerUid],
            ),
            after: _bookingSnapshot(
              courseId: target.courseId,
              dayKey: target.dayKey,
              time: target.time,
              sessionNo: targetSessionNo,
              teacherId: target.teacherId,
              teacherName: target.teacherName,
              learnerUids: [learnerUid],
            ),
            learnerUids: [learnerUid],
            rescheduleReason: rescheduleReason,
          );
        } catch (e) {
          _toast('Booking moved, but notifications failed.');
        }
      }

      if (!mounted) return;
      if (detailsSheetContext.mounted &&
          Navigator.of(detailsSheetContext).canPop()) {
        Navigator.of(detailsSheetContext).pop();
      }

      if (mounted) {
        setState(() => busyAction = false);
      }

      await _loadAllBookedSlots();
    } catch (e) {
      _toast('Reschedule failed: $e');
    } finally {
      if (mounted) {
        setState(() => busyAction = false);
      }
    }
  }

  Future<void> _changeSessionOnly(
    _AdminBookedSlot slot,
    BuildContext detailsSheetContext,
  ) async {
    if (busyAction) return;
    if (_isPastBooking(slot)) {
      _toast('Past booking locked. Admin changes are disabled.');
      return;
    }
    if (slot.learnerCount != 1) {
      _toast('Session-only change is available only for 1-learner bookings.');
      return;
    }

    var syllabus = await _loadCourseSessionChoices(slot.courseId);
    if (!mounted) return;

    var choices = _ensureSessionChoiceIncluded(
      syllabus.allChoices,
      slot.sessionNo,
    );

    final chosen = await _showSessionChoiceSheet(
      courseId: slot.courseId,
      title: 'Change Session Only',
      description:
          'Keep date, time, and teacher the same. Only the session number will change.',
      syllabus: syllabus,
      selectedSessionNo: slot.sessionNo > 0
          ? slot.sessionNo
          : choices.first.sessionNo,
    );

    if (chosen == null || chosen == slot.sessionNo) return;
    if (!mounted) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Change Session Only'),
        content: Text(
          'Keep date, time, and teacher the same. Only the session number will change.\n\n'
          '${_sessionLabel(slot.sessionNo)} → ${_sessionLabel(chosen)}\n\n'
          '${_friendlyDateLong(slot.start)} at ${slot.time}\n${slot.teacherName}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('No'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Yes, Change'),
          ),
        ],
      ),
    );

    if (ok != true) return;

    setState(() => busyAction = true);

    try {
      final reservationRef = _reservationByTeacherRef(
        slot.courseId,
        slot.dayKey,
        slot.time,
        slot.teacherId,
      );

      final tx = await reservationRef.runTransaction((Object? currentData) {
        if (currentData is! Map) return Transaction.abort();

        final node = currentData.map((k, v) => MapEntry(k.toString(), v));
        final learnersRaw = node['learners'];
        if (learnersRaw is! Map || learnersRaw.length != 1) {
          return Transaction.abort();
        }

        node['sessionNo'] = chosen;
        return Transaction.success(node);
      });

      if (!tx.committed) {
        _toast('Could not change the session number for this booking.');
        return;
      }

      final bookingKey = _bookingKey(slot.courseId, slot.dayKey, slot.time);
      await _syncBookingAttendanceSessionNo(
        bookingKey: bookingKey,
        courseId: slot.courseId,
        learnerUids: slot.learnerUids,
        sessionNo: chosen,
      );

      _toast('Session number updated ✅');
      try {
        await _dispatchBookingChange(
          action: BookingChangeAction.changeSessionSingle,
          before: _bookingSnapshot(
            courseId: slot.courseId,
            dayKey: slot.dayKey,
            time: slot.time,
            sessionNo: slot.sessionNo,
            teacherId: slot.teacherId,
            teacherName: slot.teacherName,
            learnerUids: slot.learnerUids,
          ),
          after: _bookingSnapshot(
            courseId: slot.courseId,
            dayKey: slot.dayKey,
            time: slot.time,
            sessionNo: chosen,
            teacherId: slot.teacherId,
            teacherName: slot.teacherName,
            learnerUids: slot.learnerUids,
          ),
          learnerUids: slot.learnerUids,
        );
      } catch (e) {
        _toast('Session updated, but notifications failed.');
      }

      if (!mounted) return;
      if (detailsSheetContext.mounted &&
          Navigator.of(detailsSheetContext).canPop()) {
        Navigator.of(detailsSheetContext).pop();
      }

      if (mounted) {
        setState(() => busyAction = false);
      }

      await _loadAllBookedSlots();
    } catch (e) {
      _toast('Session change failed: $e');
    } finally {
      if (mounted) {
        setState(() => busyAction = false);
      }
    }
  }

  Future<void> _syncBookingAttendanceSessionNo({
    required String bookingKey,
    required String courseId,
    required Iterable<String> learnerUids,
    required int sessionNo,
  }) async {
    final teacherAttendanceRef = _db.child('online_attendance/$bookingKey');
    final teacherAttendanceSnap = await teacherAttendanceRef.get();
    if (teacherAttendanceSnap.exists && teacherAttendanceSnap.value is Map) {
      await teacherAttendanceRef.update({
        'sessionNo': sessionNo,
        'updatedAt': ServerValue.timestamp,
      });
    }

    for (final learnerUid in learnerUids) {
      final learnerAttendanceRef = _db.child(
        'booking_progress/$learnerUid/$courseId/online_attendance/$bookingKey',
      );
      final learnerAttendanceSnap = await learnerAttendanceRef.get();
      if (learnerAttendanceSnap.exists && learnerAttendanceSnap.value is Map) {
        await learnerAttendanceRef.update({
          'sessionNo': sessionNo,
          'updatedAt': ServerValue.timestamp,
        });
      }
    }
  }

  Future<void> _changeSessionForGroup(
    _AdminBookedSlot slot,
    BuildContext detailsSheetContext,
  ) async {
    if (busyAction) return;
    if (_isPastBooking(slot)) {
      _toast('Past booking locked. Admin changes are disabled.');
      return;
    }
    if (slot.learnerCount <= 1) {
      _toast('Use Change Session Only for 1-learner bookings.');
      return;
    }

    var syllabus = await _loadCourseSessionChoices(slot.courseId);
    if (!mounted) return;

    var choices = _ensureSessionChoiceIncluded(
      syllabus.allChoices,
      slot.sessionNo,
    );

    final chosen = await _showSessionChoiceSheet(
      courseId: slot.courseId,
      title: 'Change Session for Group',
      description:
          'Keep date, time, and teacher the same. The session number will change for all learners in this slot.',
      syllabus: syllabus,
      selectedSessionNo: slot.sessionNo > 0
          ? slot.sessionNo
          : choices.first.sessionNo,
    );

    if (chosen == null || chosen == slot.sessionNo) return;
    if (!mounted) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Change Session for Group'),
        content: Text(
          'Keep date, time, and teacher the same. The session number will change for all learners in this slot.\n\n'
          '${_sessionLabel(slot.sessionNo)} → ${_sessionLabel(chosen)}\n\n'
          '${_friendlyDateLong(slot.start)} at ${slot.time}\n${slot.teacherName}\n${slot.learnerCount} learners',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('No'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Yes, Change'),
          ),
        ],
      ),
    );

    if (ok != true) return;

    setState(() => busyAction = true);

    try {
      final reservationRef = _reservationByTeacherRef(
        slot.courseId,
        slot.dayKey,
        slot.time,
        slot.teacherId,
      );

      final tx = await reservationRef.runTransaction((Object? currentData) {
        if (currentData is! Map) return Transaction.abort();

        final node = currentData.map((k, v) => MapEntry(k.toString(), v));
        final learnersRaw = node['learners'];
        if (learnersRaw is! Map || learnersRaw.length <= 1) {
          return Transaction.abort();
        }

        node['sessionNo'] = chosen;
        return Transaction.success(node);
      });

      if (!tx.committed) {
        _toast('Could not change the session number for this group.');
        return;
      }

      await _syncBookingAttendanceSessionNo(
        bookingKey: _bookingKey(slot.courseId, slot.dayKey, slot.time),
        courseId: slot.courseId,
        learnerUids: slot.learnerUids,
        sessionNo: chosen,
      );

      _toast('Group session number updated ✅');
      try {
        await _dispatchBookingChange(
          action: BookingChangeAction.changeSessionGroup,
          before: _bookingSnapshot(
            courseId: slot.courseId,
            dayKey: slot.dayKey,
            time: slot.time,
            sessionNo: slot.sessionNo,
            teacherId: slot.teacherId,
            teacherName: slot.teacherName,
            learnerUids: slot.learnerUids,
          ),
          after: _bookingSnapshot(
            courseId: slot.courseId,
            dayKey: slot.dayKey,
            time: slot.time,
            sessionNo: chosen,
            teacherId: slot.teacherId,
            teacherName: slot.teacherName,
            learnerUids: slot.learnerUids,
          ),
          learnerUids: slot.learnerUids,
        );
      } catch (e) {
        _toast('Group session updated, but notifications failed.');
      }

      if (!mounted) return;
      if (detailsSheetContext.mounted &&
          Navigator.of(detailsSheetContext).canPop()) {
        Navigator.of(detailsSheetContext).pop();
      }

      if (mounted) {
        setState(() => busyAction = false);
      }

      await _loadAllBookedSlots();
    } catch (e) {
      _toast('Group session change failed: $e');
    } finally {
      if (mounted) {
        setState(() => busyAction = false);
      }
    }
  }

  Future<String?> _pickCancelReason() {
    final completer = Completer<String?>();
    showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        String selected = 'technical';
        return StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.error_outline_rounded, color: Colors.red),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Cancel Session',
                    style: TextStyle(fontWeight: FontWeight.w900),
                  ),
                ),
              ],
            ),
            content: RadioGroup<String>(
              groupValue: selected,
              onChanged: (v) { if (v != null) setDialogState(() => selected = v); },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Why is this session being cancelled?',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 12),
                  RadioListTile<String>(
                    title: const Text('\u26a1 Teacher had a technical issue'),
                    value: 'technical',
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                  ),
                  RadioListTile<String>(
                    title: const Text('\uD83D\uDEA8 Teacher had an emergency'),
                    value: 'emergency',
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                  ),
                  RadioListTile<String>(
                    title: const Text('\u2753 Other reason'),
                    value: 'other',
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  completer.complete(null);
                  Navigator.pop(ctx);
                },
                child: const Text('Back'),
              ),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.red.shade600,
                ),
                onPressed: () {
                  completer.complete(selected);
                  Navigator.pop(ctx);
                },
                icon: const Icon(Icons.group_remove_rounded),
                label: const Text('Cancel Session'),
              ),
            ],
          ),
        );
      },
    );
    return completer.future;
  }

  Future<String?> _pickRescheduleReason() {
    final completer = Completer<String?>();
    showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        String selected = 'schedule_conflict';
        return StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.schedule_rounded, color: actionOrange),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Reschedule Reason',
                    style: TextStyle(fontWeight: FontWeight.w900),
                  ),
                ),
              ],
            ),
            content: RadioGroup<String>(
              groupValue: selected,
              onChanged: (v) { if (v != null) setDialogState(() => selected = v); },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Why is this being rescheduled?',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 12),
                  RadioListTile<String>(
                    title: const Text('\uD83D\uDCC5 Teacher schedule conflict'),
                    value: 'schedule_conflict',
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                  ),
                  RadioListTile<String>(
                    title: const Text('\uD83D\uDC64 Student request'),
                    value: 'student_request',
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                  ),
                  RadioListTile<String>(
                    title: const Text('\uD83D\uDD04 Makeup session'),
                    value: 'makeup',
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                  ),
                  RadioListTile<String>(
                    title: const Text('\u2753 Other reason'),
                    value: 'other',
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  completer.complete(null);
                  Navigator.pop(ctx);
                },
                child: const Text('Back'),
              ),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: actionOrange,
                ),
                onPressed: () {
                  completer.complete(selected);
                  Navigator.pop(ctx);
                },
                icon: const Icon(Icons.schedule_rounded),
                label: const Text('Reschedule'),
              ),
            ],
          ),
        );
      },
    );
    return completer.future;
  }

  Future<void> _cancelWholeGroup(
    _AdminBookedSlot slot,
    BuildContext detailsSheetContext,
  ) async {
    if (busyAction) return;
    if (_isPastBooking(slot) && !_isLiveBooking(slot)) {
      _toast('Past booking locked. Admin changes are disabled.');
      return;
    }
    if (slot.learnerCount <= 1) {
      _toast('Use Cancel Learner for 1-learner bookings.');
      return;
    }

    final isLive = _isLiveBooking(slot);

    String? reason;
    if (isLive) {
      reason = await _pickCancelReason();
      if (reason == null) return;
    }

    if (!isLive) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Cancel Group'),
          content: Text(
            'Cancel this group booking for all learners?\n\n'
            '${_friendlyDateLong(slot.start)} at ${slot.time}\n'
            'Teacher: ${slot.teacherName}\n'
            'Learners: ${slot.learnerCount}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('No'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red.shade600),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Yes, Cancel Group'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }

    setState(() => busyAction = true);

    try {
      Future<_AdminCancelStatus> cancelWholeAtRef(DatabaseReference ref) async {
        final tx = await ref.runTransaction((Object? currentData) {
          if (currentData is! Map) return Transaction.abort();
          final node = currentData.map((k, v) => MapEntry(k.toString(), v));
          final learnersRaw = node['learners'];
          if (learnersRaw is! Map || learnersRaw.isEmpty) {
            return Transaction.abort();
          }
          return Transaction.success(null);
        });

        if (tx.committed) return _AdminCancelStatus.cancelled;

        final snap = await ref.get();
        if (!snap.exists || snap.value == null) {
          return _AdminCancelStatus.notFound;
        }
        return _AdminCancelStatus.failed;
      }

      final nestedRef = _reservationByTeacherRef(
        slot.courseId,
        slot.dayKey,
        slot.time,
        slot.teacherId,
      );
      final nestedStatus = await cancelWholeAtRef(nestedRef);
      final legacyStatus = nestedStatus == _AdminCancelStatus.cancelled
          ? _AdminCancelStatus.cancelled
          : await cancelWholeAtRef(
              _reservationsRef(slot.courseId, slot.dayKey, slot.time),
            );
      final finalStatus = nestedStatus == _AdminCancelStatus.cancelled
          ? nestedStatus
          : legacyStatus;

      if (finalStatus == _AdminCancelStatus.failed) {
        _toast('Group cancel failed. Please try again.');
        return;
      }
      if (finalStatus == _AdminCancelStatus.notFound) {
        _toast('This group booking was already canceled. ✅');
      } else {
        _toast('Group booking canceled ✅');
        try {
          await _dispatchBookingChange(
            action: isLive
                ? BookingChangeAction.cancelGroupLive
                : BookingChangeAction.cancelGroup,
            before: _bookingSnapshot(
              courseId: slot.courseId,
              dayKey: slot.dayKey,
              time: slot.time,
              sessionNo: slot.sessionNo,
              teacherId: slot.teacherId,
              teacherName: slot.teacherName,
              learnerUids: slot.learnerUids,
            ),
            learnerUids: slot.learnerUids,
            cancelReason: reason,
          );
        } catch (e) {
          _toast('Group canceled, but notifications failed.');
        }
      }

      if (!mounted) return;
      if (detailsSheetContext.mounted &&
          Navigator.of(detailsSheetContext).canPop()) {
        Navigator.of(detailsSheetContext).pop();
      }

      if (mounted) {
        setState(() => busyAction = false);
      }

      await _loadAllBookedSlots();
    } catch (e) {
      _toast('Group cancel failed: $e');
    } finally {
      if (mounted) {
        setState(() => busyAction = false);
      }
    }
  }

  Future<void> _rescheduleWholeGroup(
    _AdminBookedSlot sourceSlot,
    BuildContext detailsSheetContext,
  ) async {
    if (busyAction) return;
    if (_isPastBooking(sourceSlot)) {
      _toast('Past booking locked. Admin changes are disabled.');
      return;
    }
    if (sourceSlot.learnerCount <= 1) {
      _toast('Use Reschedule Learner for 1-learner bookings.');
      return;
    }

    final chosen = await _pickRescheduleChoice(sourceSlot);
    if (chosen == null) return;

    final rescheduleReason = await _pickRescheduleReason();
    if (rescheduleReason == null) return;

    if (!mounted) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Reschedule Group'),
        content: Text(
          'Move all learners in this booking?\n\n'
          '${_sessionLabel(sourceSlot.sessionNo)} → ${_sessionLabel(chosen.sessionNo)}\n\n'
          'From:\n${_friendlyDateLong(sourceSlot.start)} at ${sourceSlot.time}\n${sourceSlot.teacherName}\n${sourceSlot.learnerCount} learners\n\n'
          'To:\n${_friendlyDateLong(chosen.slot.start)} at ${chosen.slot.time}\n${chosen.slot.teacherName}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('No'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Yes, Move Group'),
          ),
        ],
      ),
    );

    if (ok != true) return;

    setState(() => busyAction = true);

    try {
      final sourceRef = _reservationByTeacherRef(
        sourceSlot.courseId,
        sourceSlot.dayKey,
        sourceSlot.time,
        sourceSlot.teacherId,
      );
      final targetRef = _reservationByTeacherRef(
        chosen.slot.courseId,
        chosen.slot.dayKey,
        chosen.slot.time,
        chosen.slot.teacherId,
      );
      final sourceLearners = {
        for (final uid in sourceSlot.learnerUids) uid: true,
      };

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
        if (existingSession > 0 && existingSession != chosen.sessionNo) {
          return Transaction.abort();
        }

        final cap = chosen.slot.maxLearnersPerSlot <= 0
            ? 6
            : chosen.slot.maxLearnersPerSlot;
        final additionalLearners = sourceLearners.keys
            .where((uid) => !learners.containsKey(uid))
            .length;
        if (learners.length + additionalLearners > cap) {
          return Transaction.abort();
        }

        learners.addAll(sourceLearners);
        node['teacherId'] = chosen.slot.teacherId;
        node['teacherName'] = chosen.slot.teacherName;
        node['sessionNo'] = chosen.sessionNo;
        node['learners'] = learners;
        node['createdAt'] = ServerValue.timestamp;

        return Transaction.success(node);
      });

      if (!tx.committed) {
        _toast('Could not move the group to the selected slot.');
        return;
      }

      final removeTx = await sourceRef.runTransaction((Object? currentData) {
        if (currentData is! Map) return Transaction.abort();

        final node = currentData.map((k, v) => MapEntry(k.toString(), v));
        final learnersRaw = node['learners'];
        if (learnersRaw is! Map || learnersRaw.isEmpty) {
          return Transaction.abort();
        }

        return Transaction.success(null);
      });

      if (!removeTx.committed) {
        _toast(
          'Moved group to new slot, but old slot cleanup failed. Please refresh and check.',
        );
      } else {
        _toast('Group moved ✅');
        try {
          await _dispatchBookingChange(
            action: BookingChangeAction.rescheduleGroup,
            before: _bookingSnapshot(
              courseId: sourceSlot.courseId,
              dayKey: sourceSlot.dayKey,
              time: sourceSlot.time,
              sessionNo: sourceSlot.sessionNo,
              teacherId: sourceSlot.teacherId,
              teacherName: sourceSlot.teacherName,
              learnerUids: sourceSlot.learnerUids,
            ),
            after: _bookingSnapshot(
              courseId: chosen.slot.courseId,
              dayKey: chosen.slot.dayKey,
              time: chosen.slot.time,
              sessionNo: chosen.sessionNo,
              teacherId: chosen.slot.teacherId,
              teacherName: chosen.slot.teacherName,
              learnerUids: sourceSlot.learnerUids,
            ),
            learnerUids: sourceSlot.learnerUids,
            rescheduleReason: rescheduleReason,
          );
        } catch (e) {
          _toast('Group moved, but notifications failed.');
        }
      }

      if (!mounted) return;
      if (detailsSheetContext.mounted &&
          Navigator.of(detailsSheetContext).canPop()) {
        Navigator.of(detailsSheetContext).pop();
      }

      if (mounted) {
        setState(() => busyAction = false);
      }

      await _loadAllBookedSlots();
    } catch (e) {
      _toast('Group reschedule failed: $e');
    } finally {
      if (mounted) {
        setState(() => busyAction = false);
      }
    }
  }

  // ========================= Slot Details =========================

  Future<void> _showSessionObjectiveSheet({
    required String courseId,
    required int sessionNo,
  }) async {
    if (courseId.isEmpty || sessionNo <= 0) {
      _toast('Invalid session.');
      return;
    }

    try {
      final snap = await _db.child('syllabi/$courseId/flexible').get();
      Map<String, dynamic>? found;

      if (snap.exists && snap.value is Map) {
        final root = (snap.value as Map).map(
          (k, v) => MapEntry(k.toString(), v),
        );
        final rawUnits = root['units'];
        if (rawUnits is List) {
          int globalNo = 1;
          for (final unitRaw in rawUnits) {
            if (unitRaw is! Map) continue;
            final unit = unitRaw.map((k, v) => MapEntry(k.toString(), v));
            final rawSessions = unit['sessions'];
            if (rawSessions is! List) continue;
            for (final sessionRaw in rawSessions) {
              if (sessionRaw is! Map) continue;
              final session = sessionRaw.map(
                (k, v) => MapEntry(k.toString(), v),
              );
              if (globalNo == sessionNo) {
                found = {
                  ...session,
                  'unitTitle': (unit['title'] ?? '').toString().trim(),
                  'unitOrder': _toInt(unit['order'], fallback: 0),
                  'unitOtherTitle':
                      (unit['otherTitle'] ?? '').toString().trim(),
                };
                break;
              }
              globalNo += 1;
            }
            if (found != null) break;
          }
        }
      }

      if (!mounted) return;
      if (found == null) {
        _toast('Session details not found.');
        return;
      }

      final title = (found['title'] ?? '').toString().trim();
      final objective = (found['objective'] ?? '').toString().trim();
      final content = (found['content'] ?? '').toString().trim();
      final homework = (found['homework'] ?? '').toString().trim();
      final skillType = (found['skillType'] ?? '').toString().trim();
      final duration = _toInt(found['durationMinutes'], fallback: 0);
      final unitTitle = (found['unitTitle'] ?? '').toString().trim();
      final unitOrder = _toInt(found['unitOrder'], fallback: 0);
      final unitOtherTitle =
          (found['unitOtherTitle'] ?? '').toString().trim();
      final materialsUrl = (found['materialsUrl'] ?? '').toString().trim();
      final homeworkUrl = (found['homeworkUrl'] ?? '').toString().trim();

      final unitLabel = unitTitle.isEmpty
          ? ''
          : (unitOtherTitle.isNotEmpty
                ? '$unitOtherTitle: $unitTitle'
                : (unitOrder > 0 ? 'Unit $unitOrder: $unitTitle' : unitTitle));
      final sessionLabel = title.isEmpty
          ? 'Session $sessionNo'
          : 'Session $sessionNo — $title';

      final skillIcon = switch (skillType.toLowerCase()) {
        'listening' => Icons.headphones_rounded,
        'speaking' => Icons.record_voice_over_rounded,
        'reading' => Icons.book_rounded,
        'writing' => Icons.edit_rounded,
        'grammar' => Icons.text_fields_rounded,
        'vocabulary' => Icons.abc_rounded,
        'project' => Icons.build_circle_rounded,
        _ => Icons.menu_book_rounded,
      };

      await showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.white,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
        builder: (modalCtx) {
          final bottomPad = MediaQuery.of(modalCtx).viewPadding.bottom;
          return SafeArea(
            child: Padding(
              padding: EdgeInsets.fromLTRB(18, 8, 18, 12 + bottomPad),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (unitLabel.isNotEmpty) ...[
                    Text(
                      unitLabel,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: Colors.grey.shade600,
                        letterSpacing: 0.3,
                      ),
                    ),
                    const SizedBox(height: 2),
                  ],
                  Text(
                    sessionLabel,
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 17,
                      color: primaryBlue,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (skillType.isNotEmpty || duration > 0)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Row(
                        children: [
                          if (skillType.isNotEmpty) ...[
                            Icon(skillIcon, size: 16, color: actionOrange),
                            const SizedBox(width: 5),
                            Text(
                              skillType,
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 12,
                                color: actionOrange,
                              ),
                            ),
                          ],
                          if (skillType.isNotEmpty && duration > 0)
                            const SizedBox(width: 12),
                          if (duration > 0) ...[
                            const Icon(
                              Icons.schedule_rounded,
                              size: 16,
                              color: Color(0xFF6B7280),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '$duration min',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 12,
                                color: Colors.grey.shade600,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  if (objective.isNotEmpty) ...[
                    _SectionCard(
                      icon: Icons.psychology_rounded,
                      title: 'Objective',
                      body: objective,
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (content.isNotEmpty) ...[
                    _SectionCard(
                      icon: Icons.description_rounded,
                      title: 'Content',
                      body: content,
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (homework.isNotEmpty) ...[
                    _SectionCard(
                      icon: Icons.home_rounded,
                      title: 'Homework',
                      body: homework,
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (materialsUrl.isNotEmpty || homeworkUrl.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    if (materialsUrl.isNotEmpty)
                      _UrlChip(
                        icon: Icons.link_rounded,
                        label: 'Materials',
                        url: materialsUrl,
                      ),
                    if (homeworkUrl.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      _UrlChip(
                        icon: Icons.assignment_rounded,
                        label: 'Homework Link',
                        url: homeworkUrl,
                      ),
                    ],
                  ],
                  const SizedBox(height: 8),
                ],
              ),
            ),
          );
        },
      );
    } catch (_) {
      if (mounted) _toast('Failed to load session details.');
    }
  }

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
        final isPast = _isPastBooking(slot);
        final isLive = _isLiveBooking(slot);
        final isSingleLearner = slot.learnerCount == 1;

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
                  child: Row(
                    children: [
                      Text(
                        'Session ${slot.sessionNo <= 0 ? '—' : slot.sessionNo} • ${slot.learnerCount} learner${slot.learnerCount == 1 ? '' : 's'}',
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          color: actionOrange,
                        ),
                      ),
                      if (slot.sessionNo > 0) ...[
                        const SizedBox(width: 8),
                        SizedBox(
                          height: 28,
                          child: TextButton.icon(
                            onPressed: () =>
                                _showSessionObjectiveSheet(
                                  courseId: slot.courseId,
                                  sessionNo: slot.sessionNo,
                                ),
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              foregroundColor: actionOrange,
                            ),
                            icon: const Icon(
                              Icons.info_outline_rounded,
                              size: 16,
                            ),
                            label: const Text(
                              'Details',
                              style: TextStyle(
                                fontWeight: FontWeight.w900,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (!isSingleLearner) ...[
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final actionWidth = _sheetActionButtonWidth(
                          constraints.maxWidth,
                        );
                        return Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            SizedBox(
                              width: actionWidth,
                              child: OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: primaryBlue,
                                  side: BorderSide(
                                    color: primaryBlue.withValues(alpha: 0.25),
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 10,
                                  ),
                                ),
                                onPressed: (busyAction || isPast)
                                    ? null
                                    : () => _changeSessionForGroup(
                                        slot,
                                        sheetContext,
                                      ),
                                icon: const Icon(Icons.groups_rounded),
                                label: const Text(
                                  'Change Session for Group',
                                  style: TextStyle(fontWeight: FontWeight.w900),
                                ),
                              ),
                            ),
                            SizedBox(
                              width: actionWidth,
                              child: OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: primaryBlue,
                                  side: BorderSide(
                                    color: primaryBlue.withValues(alpha: 0.25),
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 10,
                                  ),
                                ),
                                onPressed: (busyAction || isPast)
                                    ? null
                                    : () => _rescheduleWholeGroup(
                                        slot,
                                        sheetContext,
                                      ),
                                icon: const Icon(Icons.swap_horiz_rounded),
                                label: const Text(
                                  'Reschedule Group',
                                  style: TextStyle(fontWeight: FontWeight.w900),
                                ),
                              ),
                            ),
                            SizedBox(
                              width: actionWidth,
                              child: FilledButton.icon(
                                style: FilledButton.styleFrom(
                                  backgroundColor: Colors.red.shade600,
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 10,
                                  ),
                                ),
                                onPressed: (busyAction || (isPast && !isLive))
                                    ? null
                                    : () =>
                                          _cancelWholeGroup(slot, sheetContext),
                                icon: const Icon(Icons.group_remove_rounded),
                                label: const Text(
                                  'Cancel Group',
                                  style: TextStyle(fontWeight: FontWeight.w900),
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
                if (isPast && !isLive) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(
                        Icons.lock_clock_rounded,
                        size: 16,
                        color: Colors.grey.shade600,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Past booking locked. Admin changes are disabled.',
                          style: TextStyle(
                            color: Colors.grey.shade700,
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
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
                                  LayoutBuilder(
                                    builder: (context, constraints) {
                                      final actionWidth =
                                          _sheetActionButtonWidth(
                                            constraints.maxWidth,
                                          );
                                      return Wrap(
                                        spacing: 8,
                                        runSpacing: 8,
                                        children: [
                                          if (isSingleLearner)
                                            SizedBox(
                                              width: actionWidth,
                                              child: OutlinedButton.icon(
                                                style: OutlinedButton.styleFrom(
                                                  foregroundColor: primaryBlue,
                                                  side: BorderSide(
                                                    color: primaryBlue
                                                        .withValues(
                                                          alpha: 0.25,
                                                        ),
                                                  ),
                                                  shape: RoundedRectangleBorder(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          12,
                                                        ),
                                                  ),
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        vertical: 10,
                                                      ),
                                                ),
                                                onPressed:
                                                    (busyAction || isPast)
                                                    ? null
                                                    : () => _changeSessionOnly(
                                                        slot,
                                                        sheetContext,
                                                      ),
                                                icon: const Icon(
                                                  Icons.edit_note_rounded,
                                                ),
                                                label: const Text(
                                                  'Change Session Only',
                                                  style: TextStyle(
                                                    fontWeight: FontWeight.w900,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          if (isSingleLearner)
                                            SizedBox(
                                              width: actionWidth,
                                              child: OutlinedButton.icon(
                                                style: OutlinedButton.styleFrom(
                                                  foregroundColor: primaryBlue,
                                                  side: BorderSide(
                                                    color: primaryBlue
                                                        .withValues(
                                                          alpha: 0.25,
                                                        ),
                                                  ),
                                                  shape: RoundedRectangleBorder(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          12,
                                                        ),
                                                  ),
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        vertical: 10,
                                                      ),
                                                ),
                                                onPressed:
                                                    (busyAction || isPast)
                                                    ? null
                                                    : () =>
                                                          _pickRescheduleTarget(
                                                            slot,
                                                            p.uid,
                                                            sheetContext,
                                                          ),
                                                icon: const Icon(
                                                  Icons.swap_horiz_rounded,
                                                ),
                                                label: const Text(
                                                  'Reschedule Learner',
                                                  style: TextStyle(
                                                    fontWeight: FontWeight.w900,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          SizedBox(
                                            width: actionWidth,
                                            child: FilledButton.icon(
                                              style: FilledButton.styleFrom(
                                                backgroundColor:
                                                    Colors.red.shade600,
                                                foregroundColor: Colors.white,
                                                shape: RoundedRectangleBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(12),
                                                ),
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      vertical: 10,
                                                    ),
                                              ),
                                              onPressed: (busyAction || (isPast && !isLive))
                                                  ? null
                                                  : () =>
                                                        _cancelLearnerFromSlot(
                                                          slot,
                                                          p.uid,
                                                          sheetContext,
                                                        ),
                                              icon: const Icon(
                                                Icons.close_rounded,
                                              ),
                                              label: const Text(
                                                'Cancel Learner',
                                                style: TextStyle(
                                                  fontWeight: FontWeight.w900,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ],
                                      );
                                    },
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
    final now = DateTime.now();
    final past = <_AdminBookedSlot>[];
    final live = <_AdminBookedSlot>[];
    final upcoming = <_AdminBookedSlot>[];

    for (final s in filtered) {
      if (_isLiveBooking(s)) {
        live.add(s);
        continue;
      }
      if (s.start.isAfter(now)) {
        upcoming.add(s);
        continue;
      }
      past.add(s);
    }

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
    final filteredCourses = _coursesForSelectedLevel();
    String safeCourseId = selectedCourseId ?? 'all';
    if (safeCourseId != 'all' &&
        !filteredCourses.any((c) => c.id == safeCourseId)) {
      safeCourseId = 'all';
    }
    final webDesktop = isWebDesktop(context);

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
          const SizedBox.shrink(),
          IconButton(
            tooltip: 'Refresh',
            onPressed: (loadingCourses || loadingBookings)
                ? null
                : _loadAllBookedSlots,
            icon: const Icon(Icons.refresh_rounded, color: primaryBlue),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: loadingCourses
          ? const Center(child: CircularProgressIndicator())
          : adminWebBodyFrame(
              context: context,
              maxWidth: 1680,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(10, 10, 10, 14),
                children: [
                  // Combined header, search & filters
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: uiBorder),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [

                        // Level chips
                        _buildCompactSelectors(),
                        const SizedBox(height: 6),
                        // Course dropdown + Search
                        Row(
                          children: [
                            Expanded(
                              flex: 5,
                              child: Container(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 10),
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
                                  hint: const Text('All courses'),
                                  items: [
                                    const DropdownMenuItem(
                                      value: 'all',
                                      child: Text(
                                        'All courses (booked first)',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontWeight: FontWeight.w900,
                                          color: primaryBlue,
                                          fontSize: 13,
                                        ),
                                      ),
                                    ),
                                    ...filteredCourses.map(
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
                                    ),
                                  ],
                                  onChanged: filteredCourses.isEmpty
                                      ? null
                                      : (v) async {
                                          if (v == null) return;
                                          setState(() {
                                            selectedCourseId =
                                                v == 'all' ? null : v;
                                            teacherFilter = 'all';
                                          });
                                        },
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              flex: 3,
                              child: TextField(
                                controller: searchC,
                                decoration: InputDecoration(
                                  hintText: 'Search',
                                  isDense: true,
                                  contentPadding:
                                      const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 10,
                                  ),
                                  prefixIcon: const Icon(
                                    Icons.search_rounded,
                                    size: 20,
                                  ),
                                  suffixIcon:
                                      searchC.text.trim().isEmpty
                                          ? null
                                          : IconButton(
                                              onPressed: () =>
                                                  searchC.clear(),
                                              icon: const Icon(
                                                Icons.close_rounded,
                                                size: 18,
                                              ),
                                            ),
                                  border: OutlineInputBorder(
                                    borderRadius:
                                        BorderRadius.circular(12),
                                  ),
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius:
                                        BorderRadius.circular(12),
                                    borderSide:
                                        BorderSide(color: uiBorder),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        // Filters row
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              _smallDropdown(
                                width: 140,
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
                              const SizedBox(width: 6),
                              _smallDropdown(
                                width: 120,
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
                              const SizedBox(width: 6),
                              _togglePill(
                                label: 'Group only',
                                value: onlyMultiLearner,
                                onChanged: (v) =>
                                    setState(() => onlyMultiLearner = v),
                              ),
                              const SizedBox(width: 6),
                              OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: primaryBlue,
                                  side: BorderSide(
                                    color: primaryBlue
                                        .withValues(alpha: 0.20),
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius:
                                        BorderRadius.circular(999),
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 6,
                                  ),
                                ),
                                onPressed: _clearFilters,
                                icon: const Icon(
                                  Icons.filter_alt_off_rounded,
                                  size: 16,
                                ),
                                label: const Text(
                                  'Clear',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  _Card(
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
                        : DefaultTabController(
                            length: 3,
                            initialIndex: 1,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [

                                Container(
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(color: uiBorder),
                                  ),
                                  child: TabBar(
                                    labelColor: primaryBlue,
                                    unselectedLabelColor: primaryBlue
                                        .withValues(alpha: 0.70),
                                    indicatorColor: actionOrange,
                                    tabs: [
                                      Tab(text: 'Past (${past.length})'),
                                      Tab(text: 'Live (${live.length})'),
                                      Tab(
                                        text: 'Upcoming (${upcoming.length})',
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 10),
                                SizedBox(
                                  height: webDesktop ? 520 : 540,
                                  child: TabBarView(
                                    children: [
                                      _buildBookingsPane(
                                        items: past.reversed.toList(),
                                        webDesktop: webDesktop,
                                        emptyText:
                                            'No past bookings in this selection.',
                                      ),
                                      _buildBookingsPane(
                                        items: live,
                                        webDesktop: webDesktop,
                                        emptyText:
                                            'No live bookings in this selection.',
                                      ),
                                      _buildBookingsPane(
                                        items: upcoming,
                                        webDesktop: webDesktop,
                                        emptyText:
                                            'No upcoming bookings in this selection.',
                                      ),
                                    ],
                                  ),
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

  Widget _buildWebFrozenBookingsTable(List<_AdminBookedSlot> filtered) {
    const frozenWidth = 250.0;
    const rightWidth = 900.0;

    Widget headCell(String text, double width) {
      return SizedBox(
        width: width,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontWeight: FontWeight.w900,
              color: primaryBlue,
              fontSize: 12,
            ),
          ),
        ),
      );
    }

    Widget rowCell(
      String text,
      double width, {
      Color? color,
      bool strong = false,
    }) {
      return SizedBox(
        width: width,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontWeight: strong ? FontWeight.w900 : FontWeight.w700,
              color: color ?? primaryBlue.withValues(alpha: 0.9),
              fontSize: 12,
            ),
          ),
        ),
      );
    }

    Widget frozenRow(_AdminBookedSlot s, int i) {
      final rowBg = i.isEven ? Colors.white : appBg.withValues(alpha: 0.7);
      final timeColor = _isLiveBooking(s)
          ? const Color(0xFF0B7285)
          : s.start.isBefore(DateTime.now())
          ? Colors.grey.shade700
          : actionOrange;
      return Container(
        height: 44,
        color: rowBg,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Row(
          children: [
            rowCell(_friendlyDate(s.start), 132, strong: true),
            rowCell(s.time, 98, strong: true, color: timeColor),
          ],
        ),
      );
    }

    Widget rightRow(_AdminBookedSlot s, int i) {
      final rowBg = i.isEven ? Colors.white : appBg.withValues(alpha: 0.7);
      final statusColor = _statusColorForSlot(s);
      return Container(
        height: 44,
        color: rowBg,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Row(
          children: [
            rowCell(_courseTitle(s.courseId), 190),
            rowCell(s.teacherName, 150),
            rowCell(s.sessionNo <= 0 ? '—' : '${s.sessionNo}', 76),
            rowCell('${s.learnerCount}', 76, strong: true),
            SizedBox(
              width: 150,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(999),
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
            ),
            SizedBox(
              width: 90,
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => _openSlotDetails(s),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text(
                    'View',
                    style: TextStyle(fontWeight: FontWeight.w900, fontSize: 12),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        height: 520,
        child: Row(
          children: [
            SizedBox(
              width: frozenWidth,
              child: Column(
                children: [
                  Container(
                    height: 40,
                    color: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Row(
                      children: [headCell('Day', 132), headCell('Time', 98)],
                    ),
                  ),
                  Divider(
                    height: 1,
                    color: Colors.black.withValues(alpha: 0.07),
                  ),
                  Expanded(
                    child: ListView.separated(
                      controller: _bookingRowsFrozen,
                      itemCount: filtered.length,
                      separatorBuilder: (_, _) => Divider(
                        height: 1,
                        color: Colors.black.withValues(alpha: 0.07),
                      ),
                      itemBuilder: (_, i) => frozenRow(filtered[i], i),
                    ),
                  ),
                ],
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: rightWidth,
                  child: Column(
                    children: [
                      Container(
                        height: 40,
                        color: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: Row(
                          children: [
                            headCell('Course', 190),
                            headCell('Teacher', 150),
                            headCell('Sess', 76),
                            headCell('Lrnrs', 76),
                            headCell('Status', 150),
                            headCell('Act', 90),
                          ],
                        ),
                      ),
                      Divider(
                        height: 1,
                        color: Colors.black.withValues(alpha: 0.07),
                      ),
                      Expanded(
                        child: ListView.separated(
                          controller: _bookingRowsMain,
                          itemCount: filtered.length,
                          separatorBuilder: (_, _) => Divider(
                            height: 1,
                            color: Colors.black.withValues(alpha: 0.07),
                          ),
                          itemBuilder: (_, i) => rightRow(filtered[i], i),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBookingsPane({
    required List<_AdminBookedSlot> items,
    required bool webDesktop,
    required String emptyText,
  }) {
    if (items.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          emptyText,
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
      );
    }

    if (webDesktop) {
      return _buildWebFrozenBookingsTable(items);
    }

    final safeBottom = MediaQuery.of(context).viewPadding.bottom;
    return SingleChildScrollView(
      padding: EdgeInsets.only(bottom: safeBottom + 16),
      child: ClipRRect(
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
              DataColumn(label: Text('Course')),
              DataColumn(label: Text('Teacher')),
              DataColumn(label: Text('Sess')),
              DataColumn(label: Text('Lrnrs')),
              DataColumn(label: Text('Status')),
              DataColumn(label: Text('Act')),
            ],
            rows: items.map((s) {
              final statusColor = _statusColorForSlot(s);
              final timeColor = _isLiveBooking(s)
                  ? const Color(0xFF0B7285)
                  : s.start.isBefore(DateTime.now())
                  ? Colors.grey.shade700
                  : actionOrange;

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
                        color: timeColor,
                      ),
                    ),
                  ),
                  DataCell(
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 150),
                      child: Text(
                        _courseTitle(s.courseId),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
                  DataCell(
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 110),
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
                      s.sessionNo <= 0 ? '—' : '${s.sessionNo}',
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
                        color: statusColor.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(999),
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
                      onPressed: () => _openSlotDetails(s),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 6,
                        ),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
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
    );
  }

  Widget _buildCompactSelectors() {
    final levels = _levelOptionsWithBookingsOnly();
    if (levels.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        _chip('All levels', levelFilter == 'all', () async {
          setState(() {
            levelFilter = 'all';
            if (selectedCourseId != null &&
                !_coursesForSelectedLevel().any(
                  (c) => c.id == selectedCourseId,
                )) {
              selectedCourseId = null;
            }
          });
        }),
        ...levels.map(
          (lvl) => _chip(lvl, levelFilter == lvl, () async {
            final matching = allCourses
                .where((c) => c.levelText == lvl)
                .toList();

            setState(() {
              levelFilter = lvl;
              if (selectedCourseId != null &&
                  !matching.any((c) => c.id == selectedCourseId)) {
                selectedCourseId = null;
              }
            });
          }),
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
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
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

enum _AdminCancelStatus { cancelled, notFound, failed }

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
  final int durationMinutes;
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
    required this.durationMinutes,
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

class _RescheduleChoice {
  final _AvailSlot slot;
  final int sessionNo;

  _RescheduleChoice({required this.slot, required this.sessionNo});
}

class _SessionChoiceInfo {
  final int sessionNo;
  final String title;
  final String skillType;
  final String objective;

  const _SessionChoiceInfo({
    required this.sessionNo,
    this.title = '',
    this.skillType = '',
    this.objective = '',
  });
}

class _SyllabusUnit {
  final String id;
  final String title;
  final String description;
  final int order;
  final List<_SessionChoiceInfo> sessions;

  const _SyllabusUnit({
    required this.id,
    required this.title,
    this.description = '',
    this.order = 0,
    required this.sessions,
  });
}

class _CourseSyllabus {
  final List<_SyllabusUnit> units;
  List<_SessionChoiceInfo> get allChoices =>
      units.expand((u) => u.sessions).toList();

  const _CourseSyllabus({required this.units});
}

// ========================= Small UI Widgets =========================

class _Card extends StatelessWidget {
  const _Card({this.title, required this.child});

  final String? title;
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
          if (title != null) ...[
            Text(
              title!,
              style: const TextStyle(
                fontWeight: FontWeight.w900,
                color: primaryBlue,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 8),
          ],
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
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
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

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  static const _primaryBlue = Color(0xFF1A2B48);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F9FB),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: _primaryBlue),
              const SizedBox(width: 6),
              Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 13,
                  color: _primaryBlue,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            body,
            style: TextStyle(
              fontWeight: FontWeight.w500,
              fontSize: 13,
              color: Colors.grey.shade800,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }
}

class _UrlChip extends StatelessWidget {
  const _UrlChip({
    required this.icon,
    required this.label,
    required this.url,
  });

  final IconData icon;
  final String label;
  final String url;

  static const _primaryBlue = Color(0xFF1A2B48);

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () {},
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: _primaryBlue.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: _primaryBlue.withValues(alpha: 0.15),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: _primaryBlue.withValues(alpha: 0.7)),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                  color: _primaryBlue.withValues(alpha: 0.8),
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
