import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import '../shared/human_error.dart';
import '../shared/app_feedback.dart';
import '../shared/screen_help_guide.dart';
import '../shared/teacher_tour_guide.dart';
import '../shared/study_variant.dart';

class TakeAttendanceScreen extends StatefulWidget {
  final Map<String, dynamic> classData;
  final String? existingSessionId;
  final Map<String, dynamic>? existingRecord;

  const TakeAttendanceScreen({
    super.key,
    required this.classData,
    this.existingSessionId,
    this.existingRecord,
  });

  @override
  State<TakeAttendanceScreen> createState() => _TakeAttendanceScreenState();
}

class _TakeAttendanceScreenState extends State<TakeAttendanceScreen> {
  static const primaryBlue = Color(0xFF1A2B48);
  static const actionOrange = Color(0xFFF98D28);
  static const mainText = Color(0xFF2D2D2D);
  static const secondaryText = Color(0xFF64748B);
  static const appBg = Color(0xFFF4F7F9);
  static const uiBorder = Color(0xFFD1D9E0);

  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  bool _busy = true;
  String? _error;

  DateTime _date = DateTime.now();
  int _successRate = 80;

  // Syllabus flattened sessions for picker
  List<Map<String, dynamic>> _syllabiSessions = [];

  // Meeting number (1..N), auto computed (reuses gaps after delete)
  int _meetingNumber = 1;

  // “taught” can contain multiple items (syllabus lessons + custom items)
  // Item schema:
  // - syllabus:
  //   {
  //     type:'syllabus',
  //     unitId, unitTitle, sessionId, title, sessionNumber,
  //     objective, skillType, lessonHomework
  //   }
  // - custom:
  //   { type:'custom', title, notes }
  final List<Map<String, dynamic>> _taughtItems = [];

  // Attendance switches
  final Map<String, bool> _present = {};
  List<String> _learnerUids = [];
  final Map<String, Map<String, dynamic>> _learnerInfo = {};

  // Homework
  final TextEditingController _homeworkCtrl = TextEditingController();
  String _homeworkDueDate = '';
  bool _homeworkTouchedByUser = false;
  String _lastAutofilledHomework = '';

  bool get _isEdit =>
      widget.existingSessionId != null && widget.existingSessionId!.isNotEmpty;

  String get _classId =>
      (widget.classData['class_id'] ?? widget.classData['id'] ?? '').toString();

  String get _courseId => (widget.classData['course_id'] ?? '').toString();
  String get _courseCode => (widget.classData['course_code'] ?? '').toString();
  String get _courseTitle =>
      (widget.classData['course_title'] ?? '').toString();
  String get _variantKey => normalizeVariantKey(
    (widget.classData['variantKey'] ?? widget.classData['variant'] ?? '')
        .toString(),
  );

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _homeworkCtrl.dispose();
    super.dispose();
  }

  Map<String, dynamic> _safeMap(dynamic value) {
    if (value is Map) {
      return value.map((k, v) => MapEntry(k.toString(), v));
    }
    return <String, dynamic>{};
  }

  DateTime? _parseDate(String s) {
    try {
      final parts = s.split('-');
      if (parts.length != 3) return null;
      return DateTime(
        int.parse(parts[0]),
        int.parse(parts[1]),
        int.parse(parts[2]),
      );
    } catch (_) {
      return null;
    }
  }

  String _dateStr(DateTime d) =>
      "${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}";

  int _firstMissingPositive(Set<int> used) {
    int n = 1;
    while (used.contains(n)) {
      n++;
    }
    return n;
  }

  Future<int> _computeNextMeetingNumber() async {
    final snap = await _db
        .child('classes')
        .child(_classId)
        .child('attendance')
        .get();
    if (!snap.exists) return 1;

    final used = <int>{};
    final m = _safeMap(snap.value);

    for (final entry in m.entries) {
      final rec = entry.value;
      if (rec is! Map) continue;

      final recMap = _safeMap(rec);
      final mnRaw = recMap['meetingNumber'];

      int? mn;
      if (mnRaw is num) mn = mnRaw.toInt();
      if (mnRaw is String) mn = int.tryParse(mnRaw);

      if (mn != null && mn > 0) used.add(mn);
    }

    return _firstMissingPositive(used);
  }

  Future<void> _init() async {
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      // learners
      final learnersNode = widget.classData['learners'];
      final Set<String> learnerSet = {};
      if (learnersNode is Map) {
        final learnersMap = _safeMap(learnersNode);
        learnerSet.addAll(learnersMap.keys.map((e) => e.toString()));
      }

      // restore edit mode
      if (_isEdit && widget.existingRecord != null) {
        final rec = widget.existingRecord!;

        final p = _safeMap(rec['present']);
        final a = _safeMap(rec['absent']);
        learnerSet.addAll(p.keys.map((e) => e.toString()));
        learnerSet.addAll(a.keys.map((e) => e.toString()));

        final parsed = _parseDate((rec['date'] ?? '').toString());
        if (parsed != null) _date = parsed;

        if (rec['successRate'] is num) {
          _successRate = (rec['successRate'] as num).toInt();
        }

        // homework
        final hw = _safeMap(rec['homework']);
        _homeworkCtrl.text = (hw['text'] ?? '').toString();
        _homeworkDueDate = (hw['dueDate'] ?? '').toString();
        _homeworkTouchedByUser = _homeworkCtrl.text.trim().isNotEmpty;

        // present/absent
        for (final uid in learnerSet) {
          _present[uid] = false;
        }
        for (final uid in p.keys) {
          _present[uid.toString()] = true;
        }

        // taught items restore
        _taughtItems.clear();

        // NEW format: taughtItems list
        if (rec['taughtItems'] is List) {
          final raw = (rec['taughtItems'] as List).whereType<Map>().toList();
          for (final item in raw) {
            _taughtItems.add(_safeMap(item));
          }
        } else {
          // OLD format: single taught map
          final taught = _safeMap(rec['taught']);
          if (taught.isNotEmpty) {
            _taughtItems.add({
              'type': (taught['type'] ?? 'syllabus').toString(),
              'unitId': (taught['unitId'] ?? '').toString(),
              'unitTitle': (taught['unitTitle'] ?? '').toString(),
              'sessionId': (taught['sessionId'] ?? '').toString(),
              'title': (taught['title'] ?? '').toString(),
              'sessionNumber': (taught['sessionNumber'] is num)
                  ? (taught['sessionNumber'] as num).toInt()
                  : (int.tryParse('${taught['sessionNumber']}') ?? 0),
              'objective': (taught['objective'] ?? '').toString(),
              'skillType': (taught['skillType'] ?? '').toString(),
              'lessonHomework': (taught['lessonHomework'] ?? '').toString(),
              'notes': (taught['notes'] ?? '').toString(),
            });
          }
        }

        // meeting number restore
        final mnRaw = rec['meetingNumber'];
        if (mnRaw is num) _meetingNumber = mnRaw.toInt();
        if (mnRaw is String) {
          _meetingNumber = int.tryParse(mnRaw) ?? _meetingNumber;
        }
        if (_meetingNumber <= 0) _meetingNumber = 1;
      } else {
        // new mode defaults
        for (final uid in learnerSet) {
          _present[uid] = true;
        }
        _homeworkTouchedByUser = false;
        _taughtItems.clear();
      }

      _learnerUids = learnerSet.toList()..sort();

      // load learners info
      await Future.wait(
        _learnerUids.map((uid) async {
          final snap = await _db.child('users').child(uid).get();
          if (!snap.exists) {
            _learnerInfo[uid] = {'uid': uid, 'name': uid, 'serial': ''};
            return;
          }
          final m = _safeMap(snap.value);
          final fullName = "${m['first_name'] ?? ''} ${m['last_name'] ?? ''}"
              .trim();
          _learnerInfo[uid] = {
            'uid': uid,
            'name': fullName.isEmpty ? uid : fullName,
            'serial': (m['serial'] ?? '').toString(),
          };
        }),
      );

      // load syllabus sessions for picker (+ include sessionNumber + snapshot fields)
      if (_courseId.isNotEmpty) {
        final syllabusVariant = syllabusVariantForScheduledAttendance(
          _variantKey,
        );
        var sSnap = await _db
            .child('syllabi')
            .child(_courseId)
            .child(syllabusVariant)
            .get();
        if ((!sSnap.exists || sSnap.value is! Map) &&
            syllabusVariant == 'private') {
          sSnap = await _db
              .child('syllabi')
              .child(_courseId)
              .child('inclass')
              .get();
        }
        if (sSnap.exists && sSnap.value is Map) {
          final s = _safeMap(sSnap.value);
          final units = s['units'] as List?;
          final List<Map<String, dynamic>> flat = [];

          if (units != null) {
            for (final u in units) {
              if (u is! Map) continue;
              final unit = _safeMap(u);
              final sessions = unit['sessions'] as List?;
              if (sessions != null) {
                for (final ss in sessions) {
                  if (ss is! Map) continue;
                  final sess = _safeMap(ss);
                  flat.add({
                    'unitId': (unit['id'] ?? '').toString(),
                    'unitTitle':
                        ((unit['title'] ?? '').toString().trim().isNotEmpty)
                        ? (unit['title'] ?? '').toString()
                        : (unit['description'] ?? '').toString(),
                    'sessionId': (sess['id'] ?? '').toString(),
                    'title': (sess['title'] ?? '').toString(),
                    'order': (sess['order'] is num)
                        ? (sess['order'] as num).toInt()
                        : 0,
                    'unitOrder': (unit['order'] is num)
                        ? (unit['order'] as num).toInt()
                        : 0,

                    // snapshot fields
                    'objective': (sess['objective'] ?? '').toString(),
                    'homework': (sess['homework'] ?? '').toString(),
                    'skillType': (sess['skillType'] ?? '').toString(),

                    'sessionNumber': (sess['sessionNumber'] is num)
                        ? (sess['sessionNumber'] as num).toInt()
                        : (int.tryParse('${sess['sessionNumber']}') ?? 0),
                  });
                }
              }
            }
          }

          flat.sort((a, b) {
            final cmp = (a['unitOrder'] as int).compareTo(
              b['unitOrder'] as int,
            );
            return cmp != 0
                ? cmp
                : (a['order'] as int).compareTo(b['order'] as int);
          });

          _syllabiSessions = flat;

          // In new mode: auto add first syllabus lesson if empty
          if (!_isEdit && _taughtItems.isEmpty && _syllabiSessions.isNotEmpty) {
            final first = _syllabiSessions.first;
            _taughtItems.add(_syllabusToTaughtItem(first));

            // auto-fill homework from first lesson
            _applyHomeworkAutofillFromSelectedSession(first);
          }

          // In edit mode: enrich syllabus items with latest missing fields
          if (_isEdit &&
              _taughtItems.isNotEmpty &&
              _syllabiSessions.isNotEmpty) {
            for (int i = 0; i < _taughtItems.length; i++) {
              final item = _taughtItems[i];
              if ((item['type'] ?? 'syllabus') != 'syllabus') continue;

              final sid = (item['sessionId'] ?? '').toString();
              final uid = (item['unitId'] ?? '').toString();
              final match = _syllabiSessions.where(
                (x) => x['sessionId'] == sid && x['unitId'] == uid,
              );

              if (match.isNotEmpty) {
                final s = match.first;
                _taughtItems[i] = {
                  ...item,
                  'unitTitle': (s['unitTitle'] ?? item['unitTitle'] ?? '')
                      .toString(),
                  'title': (s['title'] ?? item['title'] ?? '').toString(),
                  'sessionNumber':
                      (s['sessionNumber'] ?? item['sessionNumber'] ?? 0),
                  'objective': (item['objective'] ?? s['objective'] ?? '')
                      .toString(),
                  'skillType': (item['skillType'] ?? s['skillType'] ?? '')
                      .toString(),
                  'lessonHomework':
                      (item['lessonHomework'] ?? s['homework'] ?? '')
                          .toString(),
                };
              }
            }
          }
        }
      }

      // Auto meetingNumber ONLY in new mode
      if (!_isEdit && _classId.isNotEmpty) {
        _meetingNumber = await _computeNextMeetingNumber();
      }

      setState(() => _busy = false);
    } catch (e) {
      setState(() {
        _error = toHumanError(
          e,
          fallback: 'Could not load attendance data. Please try again.',
        );
        _busy = false;
      });
    }
  }

  Map<String, dynamic> _syllabusToTaughtItem(Map<String, dynamic> session) {
    return {
      'type': 'syllabus',
      'unitId': (session['unitId'] ?? '').toString(),
      'unitTitle': (session['unitTitle'] ?? '').toString(),
      'sessionId': (session['sessionId'] ?? '').toString(),
      'title': (session['title'] ?? '').toString(),
      'sessionNumber': (session['sessionNumber'] is num)
          ? (session['sessionNumber'] as num).toInt()
          : (int.tryParse('${session['sessionNumber']}') ?? 0),

      // snapshot fields for history
      'objective': (session['objective'] ?? '').toString(),
      'skillType': (session['skillType'] ?? '').toString(),
      'lessonHomework': (session['homework'] ?? '').toString(),
    };
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _pickHomeworkDueDate() async {
    final init = _parseDate(_homeworkDueDate) ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: init,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => _homeworkDueDate = _dateStr(picked));
  }

  Future<bool> _confirmDuplicateDialog() async {
    return (await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Duplicate Date'),
            content: const Text(
              'Attendance already exists for this date. Save anyway?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Save'),
              ),
            ],
          ),
        )) ??
        false;
  }

  // Homework autofill from syllabus session
  void _applyHomeworkAutofillFromSelectedSession(Map<String, dynamic> session) {
    final hwFromSyllabus = (session['homework'] ?? '').toString().trim();
    if (hwFromSyllabus.isEmpty) return;

    final currentHw = _homeworkCtrl.text.trim();

    if (_homeworkTouchedByUser) return;

    if (currentHw.isEmpty || currentHw == _lastAutofilledHomework) {
      _homeworkCtrl.text = hwFromSyllabus;
      _lastAutofilledHomework = hwFromSyllabus;
    }
  }

  Future<void> _openSyllabusLessonPickerToAdd() async {
    if (_syllabiSessions.isEmpty) {
      AppToast.fromSnackBar(
        context,
        const SnackBar(
          content: Text('No syllabus sessions found for this course'),
        ),
      );
      return;
    }

    final chosen = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 44,
                  height: 5,
                  decoration: BoxDecoration(
                    color: uiBorder,
                    borderRadius: BorderRadius.circular(100),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: const [
                    Icon(Icons.menu_book, color: primaryBlue),
                    SizedBox(width: 10),
                    Text(
                      'Add Lesson Taught',
                      style: TextStyle(
                        color: primaryBlue,
                        fontWeight: FontWeight.w900,
                        fontSize: 16,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: _syllabiSessions.length,
                    separatorBuilder: (_, _) => const Divider(height: 12),
                    itemBuilder: (_, i) {
                      final s = _syllabiSessions[i];

                      final unitTitle = (s['unitTitle'] ?? '').toString();
                      final title = (s['title'] ?? '').toString();
                      final objective = (s['objective'] ?? '')
                          .toString()
                          .trim();
                      final skillType = (s['skillType'] ?? '')
                          .toString()
                          .trim();
                      final hasHomework = (s['homework'] ?? '')
                          .toString()
                          .trim()
                          .isNotEmpty;
                      final sn = (s['sessionNumber'] is num)
                          ? (s['sessionNumber'] as num).toInt()
                          : (int.tryParse('${s['sessionNumber']}') ?? 0);

                      return InkWell(
                        onTap: () => Navigator.pop(ctx, s),
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: uiBorder),
                            color: Colors.white,
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              CircleAvatar(
                                radius: 16,
                                backgroundColor: appBg,
                                child: const Icon(
                                  Icons.school,
                                  size: 18,
                                  color: primaryBlue,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      unitTitle,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: secondaryText,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      sn > 0 ? "Session $sn • $title" : title,
                                      style: const TextStyle(
                                        color: primaryBlue,
                                        fontWeight: FontWeight.w900,
                                        fontSize: 14,
                                      ),
                                    ),
                                    if (objective.isNotEmpty) ...[
                                      const SizedBox(height: 6),
                                      Text(
                                        objective,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: mainText,
                                          fontSize: 12,
                                          height: 1.25,
                                        ),
                                      ),
                                    ],
                                    const SizedBox(height: 8),
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 8,
                                      children: [
                                        if (skillType.isNotEmpty)
                                          _chip(
                                            icon: Icons.category,
                                            text: skillType,
                                            tint: primaryBlue,
                                          ),
                                        if (hasHomework)
                                          _chip(
                                            icon: Icons.assignment_turned_in,
                                            text: 'Homework',
                                            tint: actionOrange,
                                          ),
                                      ],
                                    ),
                                  ],
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

    if (chosen != null) {
      setState(() {
        _taughtItems.add(_syllabusToTaughtItem(chosen));
      });

      _applyHomeworkAutofillFromSelectedSession(chosen);
    }
  }

  Future<void> _openCustomTaughtDialog() async {
    final titleC = TextEditingController();
    final notesC = TextEditingController();

    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add Custom Lesson'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleC,
              decoration: const InputDecoration(
                labelText: 'Title *',
                hintText: 'Example: Meeting / Review / Quiz',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: notesC,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'Notes (optional)',
                hintText: 'Any details…',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              if (titleC.text.trim().isEmpty) return;
              Navigator.pop(ctx, true);
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );

    if (res == true) {
      setState(() {
        _taughtItems.add({
          'type': 'custom',
          'title': titleC.text.trim(),
          'notes': notesC.text.trim(),
        });
      });
    }
  }

  void _removeTaughtAt(int index) {
    setState(() {
      if (index >= 0 && index < _taughtItems.length) {
        _taughtItems.removeAt(index);
      }
    });
  }

  Widget _chip({
    required IconData icon,
    required String text,
    required Color tint,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: tint.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: tint),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              color: tint,
              fontWeight: FontWeight.w800,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _saveAttendance() async {
    if (_classId.isEmpty) {
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('Missing class id')),
      );
      return;
    }
    if (_taughtItems.isEmpty) {
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('Please add at least 1 taught lesson')),
      );
      return;
    }

    setState(() => _busy = true);

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw Exception("Not logged in");

      final dateStr = _dateStr(_date);

      if (!_isEdit) {
        final attendanceSnap = await _db
            .child('classes')
            .child(_classId)
            .child('attendance')
            .get();

        bool duplicateExists = false;

        if (attendanceSnap.exists && attendanceSnap.value is Map) {
          final attendanceMap = _safeMap(attendanceSnap.value);

          for (final entry in attendanceMap.entries) {
            final rec = entry.value;
            if (rec is! Map) continue;

            final recMap = _safeMap(rec);
            final recDate = (recMap['date'] ?? '').toString().trim();

            if (recDate == dateStr) {
              duplicateExists = true;
              break;
            }
          }
        }

        if (duplicateExists && !(await _confirmDuplicateDialog())) {
          setState(() => _busy = false);
          return;
        }
      }

      final teacherSnap = await _db.child('users').child(user.uid).get();
      final tm = teacherSnap.exists
          ? _safeMap(teacherSnap.value)
          : <String, dynamic>{};
      final teacherName = "${tm['first_name'] ?? ''} ${tm['last_name'] ?? ''}"
          .trim();

      final sessionId = _isEdit
          ? widget.existingSessionId!
          : DateTime.now().millisecondsSinceEpoch.toString();

      final Map<String, bool> presentMap = {};
      final Map<String, bool> absentMap = {};
      for (final uid in _learnerUids) {
        (_present[uid] ?? false)
            ? presentMap[uid] = true
            : absentMap[uid] = true;
      }

      final hwText = _homeworkCtrl.text.trim();
      final prevHw = _safeMap(widget.existingRecord?['homework']);
      final hwCreatedAt =
          prevHw['createdAt'] ??
          (widget.existingRecord?['createdAt'] ?? ServerValue.timestamp);

      final Map<String, dynamic>? homeworkObj =
          (hwText.isEmpty && _homeworkDueDate.isEmpty)
          ? null
          : {
              'text': hwText,
              'dueDate': _homeworkDueDate,
              'createdAt': hwCreatedAt,
              'updatedAt': ServerValue.timestamp,
            };

      // Backward-compatible single taught (first item)
      final first = _taughtItems.first;
      Map<String, dynamic> taughtSingle;
      if ((first['type'] ?? 'syllabus') == 'syllabus') {
        taughtSingle = {
          'unitId': (first['unitId'] ?? '').toString(),
          'unitTitle': (first['unitTitle'] ?? '').toString(),
          'sessionId': (first['sessionId'] ?? '').toString(),
          'title': (first['title'] ?? '').toString(),
          'sessionNumber': (first['sessionNumber'] is num)
              ? (first['sessionNumber'] as num).toInt()
              : (int.tryParse('${first['sessionNumber']}') ?? 0),
          'objective': (first['objective'] ?? '').toString(),
          'skillType': (first['skillType'] ?? '').toString(),
          'lessonHomework': (first['lessonHomework'] ?? '').toString(),
        };
      } else {
        taughtSingle = {
          'unitId': '',
          'unitTitle': '',
          'sessionId': '',
          'title': (first['title'] ?? '').toString(),
          'sessionNumber': 0,
          'type': 'custom',
          'notes': (first['notes'] ?? '').toString(),
        };
      }

      final classRecord = {
        'sessionId': sessionId,
        'date': dateStr,
        'updatedAt': ServerValue.timestamp,
        'createdAt':
            widget.existingRecord?['createdAt'] ?? ServerValue.timestamp,
        'meetingNumber': _meetingNumber,
        'teacherUid': user.uid,
        'teacherName': teacherName,
        'course_id': _courseId,
        'course_code': _courseCode,
        'course_title': _courseTitle,
        'successRate': _successRate,

        // multi taught with saved snapshot fields
        'taughtItems': _taughtItems,

        // old single taught for compatibility
        'taught': taughtSingle,

        'present': presentMap,
        'absent': absentMap,
        if (homeworkObj != null) 'homework': homeworkObj,
      };

      final Map<String, dynamic> updates = {
        'classes/$_classId/attendance/$sessionId': classRecord,
      };

      // Also write to each learner course node
      for (final lUid in _learnerUids) {
        final cSnap = await _db
            .child('users')
            .child(lUid)
            .child('courses')
            .get();

        if (!cSnap.exists) continue;

        final courses = _safeMap(cSnap.value);

        String? targetKey;

        for (final entry in courses.entries) {
          final val = entry.value;

          if (val is! Map) continue;

          final valMap = _safeMap(val);

          final classNode = _safeMap(valMap['class']);
          if (classNode.isEmpty) continue;

          final cid = (classNode['class_id'] ?? '').toString();

          if (cid == _classId) {
            targetKey = entry.key.toString();
            break;
          }
        }

        if (targetKey != null) {
          updates['users/$lUid/courses/$targetKey/attendance/$sessionId'] = {
            ...classRecord,
            'class_id': _classId,
            'course_id': _courseId,
            'status': (_present[lUid] ?? false) ? 'present' : 'absent',
            'homework': homeworkObj != null
                ? {'text': hwText, 'dueDate': _homeworkDueDate}
                : null,
          };
        }
      }

      await _db.update(updates);

      if (!mounted) return;
      AppToast.fromSnackBar(
        context,
        SnackBar(content: Text(_isEdit ? 'Updated ✅' : 'Saved ✅')),
      );
      Navigator.pop(context);
    } catch (e) {
      setState(() {
        _error = toHumanError(
          e,
          fallback: 'Could not save attendance. Please try again.',
        );
        _busy = false;
      });
    }
  }

  Widget _sectionLabel(String text) => Padding(
    padding: const EdgeInsets.only(left: 4, bottom: 8),
    child: Row(
      children: [
        Container(
          width: 6,
          height: 14,
          decoration: BoxDecoration(
            color: actionOrange.withValues(alpha: 0.9),
            borderRadius: BorderRadius.circular(99),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          text,
          style: const TextStyle(
            color: secondaryText,
            fontSize: 11,
            fontWeight: FontWeight.w900,
            letterSpacing: 1.2,
          ),
        ),
      ],
    ),
  );

  Widget _buildLessonCard() {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: uiBorder),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _courseTitle,
              style: const TextStyle(
                color: primaryBlue,
                fontWeight: FontWeight.w900,
                fontSize: 18,
              ),
            ),
            const Divider(height: 24),
            Row(
              children: [
                const Icon(Icons.event, size: 20, color: primaryBlue),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Date: ${_dateStr(_date)}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                TextButton(onPressed: _pickDate, child: const Text("Change")),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                const Icon(
                  Icons.confirmation_number,
                  size: 20,
                  color: primaryBlue,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Session Count: $_meetingNumber',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                if (!_isEdit)
                  Text(
                    'Auto',
                    style: TextStyle(
                      color: Colors.black.withValues(alpha: 0.55),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            const Text(
              "Lessons Taught (this meeting)",
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w900,
                color: primaryBlue,
              ),
            ),
            const SizedBox(height: 8),
            if (_taughtItems.isEmpty)
              Text(
                "No lessons added yet.",
                style: TextStyle(color: Colors.black.withValues(alpha: 0.6)),
              )
            else
              Column(
                children: List.generate(_taughtItems.length, (i) {
                  final item = _taughtItems[i];
                  final type = (item['type'] ?? 'syllabus').toString();

                  if (type == 'custom') {
                    final title = (item['title'] ?? '').toString();
                    final notes = (item['notes'] ?? '').toString().trim();
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: uiBorder),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          CircleAvatar(
                            radius: 16,
                            backgroundColor: actionOrange.withValues(
                              alpha: 0.12,
                            ),
                            child: const Icon(
                              Icons.edit_note,
                              color: actionOrange,
                              size: 18,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  title.isEmpty ? '(Custom)' : title,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w900,
                                    color: primaryBlue,
                                  ),
                                ),
                                if (notes.isNotEmpty) ...[
                                  const SizedBox(height: 4),
                                  Text(
                                    notes,
                                    style: TextStyle(
                                      color: Colors.black.withValues(
                                        alpha: 0.65,
                                      ),
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 8),
                                _chip(
                                  icon: Icons.star,
                                  text: 'Custom',
                                  tint: actionOrange,
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            onPressed: () => _removeTaughtAt(i),
                            tooltip: 'Remove',
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ),
                    );
                  }

                  // syllabus
                  final unitTitle = (item['unitTitle'] ?? '').toString();
                  final title = (item['title'] ?? '').toString();
                  final objective = (item['objective'] ?? '').toString().trim();
                  final skillType = (item['skillType'] ?? '').toString().trim();
                  final hasLessonHomework = (item['lessonHomework'] ?? '')
                      .toString()
                      .trim()
                      .isNotEmpty;
                  final snRaw = item['sessionNumber'];
                  final sn = (snRaw is num)
                      ? snRaw.toInt()
                      : (int.tryParse('$snRaw') ?? 0);

                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: uiBorder),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        CircleAvatar(
                          radius: 16,
                          backgroundColor: appBg,
                          child: const Icon(
                            Icons.menu_book,
                            color: primaryBlue,
                            size: 18,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                unitTitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: secondaryText,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                sn > 0 ? "Session $sn • $title" : title,
                                style: const TextStyle(
                                  color: primaryBlue,
                                  fontWeight: FontWeight.w900,
                                  fontSize: 14,
                                ),
                              ),
                              if (objective.isNotEmpty) ...[
                                const SizedBox(height: 6),
                                Text(
                                  objective,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: mainText,
                                    fontSize: 12,
                                    height: 1.25,
                                  ),
                                ),
                              ],
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  _chip(
                                    icon: Icons.check,
                                    text: 'Syllabus',
                                    tint: primaryBlue,
                                  ),
                                  if (skillType.isNotEmpty)
                                    _chip(
                                      icon: Icons.category,
                                      text: skillType,
                                      tint: primaryBlue,
                                    ),
                                  if (hasLessonHomework)
                                    _chip(
                                      icon: Icons.assignment_turned_in,
                                      text: 'Lesson Homework',
                                      tint: actionOrange,
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          onPressed: () => _removeTaughtAt(i),
                          tooltip: 'Remove',
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                  );
                }),
              ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _openSyllabusLessonPickerToAdd,
                    icon: const Icon(Icons.add),
                    label: const Text('Add syllabus lesson'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _openCustomTaughtDialog,
                    icon: const Icon(Icons.edit),
                    label: const Text('Add custom'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSuccessRateCard() {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: uiBorder),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  "Success Rate",
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: primaryBlue,
                  ),
                ),
                Text(
                  "$_successRate%",
                  style: const TextStyle(
                    color: actionOrange,
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                  ),
                ),
              ],
            ),
            Slider(
              value: _successRate.toDouble(),
              min: 0,
              max: 100,
              divisions: 10,
              activeColor: actionOrange,
              onChanged: (v) => setState(() => _successRate = v.round()),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHomeworkCard() {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: uiBorder),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _homeworkCtrl,
              minLines: 12,
              maxLines: 12,
              keyboardType: TextInputType.multiline,
              onChanged: (v) {
                if (v.trim().isNotEmpty && !_homeworkTouchedByUser) {
                  setState(() => _homeworkTouchedByUser = true);
                }
                if (v.trim().isEmpty && _homeworkTouchedByUser) {
                  setState(() {
                    _homeworkTouchedByUser = false;
                    _lastAutofilledHomework = '';
                  });
                }
              },
              decoration: InputDecoration(
                hintText: "Enter homework details...",
                labelText: "Homework Instructions",
                labelStyle: const TextStyle(fontWeight: FontWeight.w800),
                filled: true,
                fillColor: appBg,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 12),
            InkWell(
              onTap: _pickHomeworkDueDate,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: uiBorder),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.history_edu, size: 20, color: primaryBlue),
                    const SizedBox(width: 10),
                    Text(
                      _homeworkDueDate.isEmpty
                          ? "No Due Date"
                          : "Due: $_homeworkDueDate",
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const Spacer(),
                    const Icon(
                      Icons.calendar_month,
                      size: 18,
                      color: secondaryText,
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

  Widget _buildLearnerTile(String uid) {
    final info = _learnerInfo[uid] ?? {'name': uid, 'serial': ''};
    final isPresent = _present[uid] ?? false;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: uiBorder),
      ),
      child: ListTile(
        title: Text(
          (info['name'] ?? uid).toString(),
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
        ),
        trailing: Switch(
          value: isPresent,
          activeThumbColor: Colors.green,
          onChanged: (v) => setState(() => _present[uid] = v),
        ),
        leading: CircleAvatar(
          backgroundColor: isPresent
              ? Colors.green.withValues(alpha: 0.1)
              : Colors.red.withValues(alpha: 0.1),
          child: Icon(
            isPresent ? Icons.check : Icons.close,
            color: isPresent ? Colors.green : Colors.red,
            size: 20,
          ),
        ),
      ),
    );
  }

  Widget _buildErrorState() => Center(
    child: Text(_error!, style: const TextStyle(color: Colors.red)),
  );

  @override
  Widget build(BuildContext context) {
    TeacherTourGuide.schedule(
      context,
      screenId: 'teacher_take_attendance',
      hints: const [
        TeacherTourHint(
          title: 'Take attendance',
          line:
              'Mark learners as present or absent, then save this attendance session.',
        ),
      ],
    );

    return Scaffold(
      backgroundColor: appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
        title: Text(
          _isEdit ? 'Edit Session' : 'Take Attendance',
          style: const TextStyle(
            color: primaryBlue,
            fontWeight: FontWeight.w900,
          ),
        ),
        actions: [
          const SizedBox.shrink(),
        ],
      ),
      body: _busy
          ? const Center(child: CircularProgressIndicator(color: primaryBlue))
          : _error != null
          ? _buildErrorState()
          : _buildForm(),
    );
  }

  Widget _buildForm() {
    final presentCount = _present.values.where((v) => v).length;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _sectionLabel("LESSON DETAILS"),
        _buildLessonCard(),
        const SizedBox(height: 20),
        _sectionLabel("HOMEWORK"),
        _buildHomeworkCard(),
        const SizedBox(height: 20),
        _sectionLabel("PROGRESS"),
        _buildSuccessRateCard(),
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _sectionLabel("LEARNERS"),
            Text(
              "$presentCount/${_learnerUids.length} Present",
              style: const TextStyle(
                color: primaryBlue,
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
          ],
        ),
        ..._learnerUids.map(_buildLearnerTile),
        const SizedBox(height: 30),
        ElevatedButton(
          onPressed: _saveAttendance,
          style: ElevatedButton.styleFrom(
            backgroundColor: actionOrange,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: Text(
            _isEdit ? 'UPDATE SESSION' : 'SAVE ATTENDANCE',
            style: const TextStyle(
              fontWeight: FontWeight.w900,
              letterSpacing: 1.1,
            ),
          ),
        ),
        const SizedBox(height: 40),
      ],
    );
  }
}
