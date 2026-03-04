// ✅ FULL REPLACEMENT: lib/admin/admin_booking.dart
//
// Updated per your decisions:
// ✅ 1) Total sessions (N) is now AUTOMATIC based on included sessions (checkbox).
//    - Removed the manual "Total sessions (N)" input.
//    - N = count(included sessions)
// ✅ Admin can still EDIT per-session details (Title + Objectives required).
// ✅ Admin sets only:
//    - K = min choices per session within 4 weeks
// ✅ Save writes:
//    booking_curriculum/<courseId> (sessions 1..N with full details)
//    booking_config/courses/<courseId> enabled + totalLessons(N) + coverageTarget{weeks:4, minChoicesPerSession:K}
//
// NOTE: Teacher enforcement is later (as you said).

import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';

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

  // ===== RTDB refs =====
  final DatabaseReference _configRef = FirebaseDatabase.instance.ref('booking_config');
  final DatabaseReference _coursesRef = FirebaseDatabase.instance.ref('courses');
  final DatabaseReference _syllabiRef = FirebaseDatabase.instance.ref('syllabi');
  final DatabaseReference _curriculumRef = FirebaseDatabase.instance.ref('booking_curriculum');

  // ===== Courses =====
  bool loadingCourses = true;
  List<_CourseItem> allCourses = [];
  String? selectedCourseId;

  // ===== Builder =====
  bool loadingSyllabus = false;
  bool saving = false;

  // Each item is a session row loaded from syllabus, editable by admin
  // keys used:
  // include(bool), unitTitle, unitId, unitOrder,
  // sessionTitle, sessionId, skillType, sessionOrder,
  // objective, content, homework, durationMinutes
  List<Map<String, dynamic>> suggested = [];

  // Admin input: K (per 4 weeks)
  final minChoicesC = TextEditingController(text: '2');

  @override
  void initState() {
    super.initState();
    _loadCourses();
  }

  @override
  void dispose() {
    minChoicesC.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  // ========================= Data =========================

  Future<void> _loadCourses() async {
    setState(() => loadingCourses = true);

    try {
      final snap = await _coursesRef.get();
      final v = snap.value;

      final List<_CourseItem> out = [];

      if (v is Map) {
        final root = v.map((k, vv) => MapEntry(k.toString(), vv));

        root.forEach((courseId, courseVal) {
          if (courseVal is! Map) return;
          final m = courseVal.map((k, vv) => MapEntry(k.toString(), vv));

          final status = (m['status'] ?? '').toString().toLowerCase().trim();
          if (status.isNotEmpty && status != 'published') return;

          final title = (m['title'] ?? '').toString().trim();
          final levelTxt = (m['level'] ?? '').toString().trim();
          final category = (m['category'] ?? '').toString().trim();
          final orderIndex = (m['order_index'] is num) ? (m['order_index'] as num).toInt() : 999;

          out.add(
            _CourseItem(
              id: courseId,
              title: title.isEmpty ? 'Untitled' : title,
              levelText: levelTxt,
              category: category,
              orderIndex: orderIndex,
            ),
          );
        });
      }

      out.sort((a, b) {
        if (a.orderIndex != b.orderIndex) return a.orderIndex.compareTo(b.orderIndex);
        return a.title.compareTo(b.title);
      });

      setState(() {
        allCourses = out;
        selectedCourseId ??= allCourses.isNotEmpty ? allCourses.first.id : null;
      });

      if (allCourses.isEmpty) _toast('No published courses found in /courses.');
    } catch (e) {
      _toast('Failed loading courses: $e');
    } finally {
      if (!mounted) return;
      setState(() => loadingCourses = false);
    }
  }

  _CourseItem? _selectedCourse() {
    final id = selectedCourseId;
    if (id == null) return null;
    for (final c in allCourses) {
      if (c.id == id) return c;
    }
    return null;
  }

  Future<void> _loadSuggestedFromSyllabus() async {
    final courseId = selectedCourseId;
    if (courseId == null || courseId.isEmpty) {
      _toast('Please select a course first.');
      return;
    }

    setState(() {
      loadingSyllabus = true;
      suggested = [];
    });

    try {
      final snap = await _syllabiRef.child(courseId).get();
      final v = snap.value;

      if (v is! Map) {
        _toast('No syllabus found at syllabi/$courseId');
        return;
      }

      final m = v.map((k, vv) => MapEntry(k.toString(), vv));
      final units = m['units'];

      if (units is! List) {
        _toast('Syllabus format unexpected: units is not a List.');
        return;
      }

      final List<Map<String, dynamic>> out = [];

      for (final u in units) {
        if (u is! Map) continue;
        final unit = u.map((k, vv) => MapEntry(k.toString(), vv));

        final unitTitle = (unit['title'] ?? '').toString();
        final unitId = (unit['id'] ?? '').toString();
        final unitOrder = unit['order'] ?? 0;

        final sessions = unit['sessions'];
        if (sessions is! List) continue;

        for (final s in sessions) {
          if (s is! Map) continue;
          final sess = s.map((k, vv) => MapEntry(k.toString(), vv));

          final title = (sess['title'] ?? '').toString();
          final id = (sess['id'] ?? '').toString();
          final skillType = (sess['skillType'] ?? '').toString();
          final order = sess['order'] ?? 0;
          final sessionNumber = (sess['sessionNumber'] is num)
              ? (sess['sessionNumber'] as num).toInt()
              : int.tryParse('${sess['sessionNumber']}') ?? 0;
          out.add({
            'include': true,
            'unitTitle': unitTitle,
            'unitId': unitId,
            'unitOrder': unitOrder,
            'sessionTitle': title,
            'sessionId': id,
            'skillType': skillType,
            'sessionOrder': order,
            'sessionNumber': sessionNumber, // ✅ from syllabus
            'objective': (sess['objective'] ?? '').toString(),
            'content': (sess['content'] ?? '').toString(),
            'homework': (sess['homework'] ?? '').toString(),
            'durationMinutes': (sess['durationMinutes'] ?? 0),
          });
        }
      }

      out.sort((a, b) {
        final an = (a['sessionNumber'] as num?)?.toInt() ?? 0;
        final bn = (b['sessionNumber'] as num?)?.toInt() ?? 0;

        // ✅ If both have sessionNumber, sort by it
        if (an > 0 && bn > 0 && an != bn) return an.compareTo(bn);

        // fallback to existing order
        final u = (a['unitOrder'] as num?)?.toInt() ?? 0;
        final uu = (b['unitOrder'] as num?)?.toInt() ?? 0;
        if (u != uu) return u.compareTo(uu);

        final s = (a['sessionOrder'] as num?)?.toInt() ?? 0;
        final ss = (b['sessionOrder'] as num?)?.toInt() ?? 0;
        return s.compareTo(ss);
      });

      setState(() => suggested = out);
      _toast('Loaded ${out.length} sessions ✅');
    } catch (e) {
      _toast('Load failed: $e');
    } finally {
      if (!mounted) return;
      setState(() => loadingSyllabus = false);
    }
  }

  void _autoExcludeCommon() {
    if (suggested.isEmpty) return;
    setState(() {
      for (final item in suggested) {
        final unitTitle = (item['unitTitle'] ?? '').toString().toLowerCase();
        final sessionTitle = (item['sessionTitle'] ?? '').toString().toLowerCase();

        final isPreUnit = unitTitle.contains('pre-unit') || unitTitle.contains('pre unit');
        final isMock = sessionTitle.contains('mock');
        final isProject = sessionTitle.contains('project');

        item['include'] = !(isPreUnit || isMock || isProject);
      }
    });
    _toast('Auto-excluded Pre-unit / Mock / Project (you can still edit).');
  }

  bool _isMissingDetails(Map<String, dynamic> item) {
    final title = (item['sessionTitle'] ?? '').toString().trim();
    final obj = (item['objective'] ?? '').toString().trim();
    return title.isEmpty || obj.isEmpty;
  }

  int _includedCount() => suggested.where((x) => x['include'] == true).length;

  int _missingDetailsIncludedCount() =>
      suggested.where((x) => x['include'] == true && _isMissingDetails(x)).length;

  Future<void> _editSessionDetails(int index) async {
    final item = suggested[index];

    final titleC = TextEditingController(text: (item['sessionTitle'] ?? '').toString());
    final objectiveC = TextEditingController(text: (item['objective'] ?? '').toString());
    final contentC = TextEditingController(text: (item['content'] ?? '').toString());
    final homeworkC = TextEditingController(text: (item['homework'] ?? '').toString());
    final durationC = TextEditingController(text: (item['durationMinutes'] ?? 0).toString());

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) {
        return Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 12,
            bottom: MediaQuery.of(context).viewInsets.bottom + MediaQuery.of(context).padding.bottom + 16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Session details',
                style: TextStyle(fontWeight: FontWeight.w900, color: primaryBlue, fontSize: 16),
              ),
              const SizedBox(height: 10),
              _Input(
                controller: titleC,
                label: 'Title (required)',
                hint: 'Example: Alphabet & Greetings',
                maxLines: 2,
              ),
              const SizedBox(height: 10),
              _Input(
                controller: objectiveC,
                label: 'Objectives (required)',
                hint: 'What will learner achieve?',
                maxLines: 4,
              ),
              const SizedBox(height: 10),
              _Input(
                controller: contentC,
                label: 'Content (optional)',
                hint: 'Topics / notes for teacher & learner',
                maxLines: 4,
              ),
              const SizedBox(height: 10),
              _Input(
                controller: homeworkC,
                label: 'Homework (optional)',
                hint: 'Homework tasks / exercises',
                maxLines: 3,
              ),
              const SizedBox(height: 10),
              _Input(
                controller: durationC,
                label: 'Duration minutes (optional)',
                hint: 'Example: 30',
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        side: BorderSide(color: primaryBlue.withOpacity(0.25)),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      onPressed: () => Navigator.pop(context),
                      child: const Text(
                        'Cancel',
                        style: TextStyle(fontWeight: FontWeight.w900, color: primaryBlue),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: actionOrange,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      onPressed: () {
                        final t = titleC.text.trim();
                        final o = objectiveC.text.trim();
                        if (t.isEmpty || o.isEmpty) {
                          _toast('Title + Objectives are required.');
                          return;
                        }

                        final dur = int.tryParse(durationC.text.trim()) ?? 0;

                        setState(() {
                          suggested[index]['sessionTitle'] = t;
                          suggested[index]['objective'] = o;
                          suggested[index]['content'] = contentC.text.trim();
                          suggested[index]['homework'] = homeworkC.text.trim();
                          suggested[index]['durationMinutes'] = dur;
                        });

                        Navigator.pop(context);
                      },
                      child: const Text('Save', style: TextStyle(fontWeight: FontWeight.w900)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );

    titleC.dispose();
    objectiveC.dispose();
    contentC.dispose();
    homeworkC.dispose();
    durationC.dispose();
  }

  Future<void> _saveCurriculumAndEnable() async {
    final courseId = selectedCourseId;
    final course = _selectedCourse();

    if (courseId == null || courseId.isEmpty || course == null) {
      _toast('Select a course first.');
      return;
    }
    if (suggested.isEmpty) {
      _toast('Load syllabus first.');
      return;
    }

    int minChoices = int.tryParse(minChoicesC.text.trim()) ?? 2;
    if (minChoices <= 0) minChoices = 1;

    final included = suggested.where((x) => x['include'] == true).toList();
    final desiredN = included.length; // ✅ AUTO: N = included count

    if (desiredN <= 0) {
      _toast('Please include at least 1 session.');
      return;
    }

    // Validate required details for ALL included sessions (since all become N)
    for (int i = 0; i < desiredN; i++) {
      final it = included[i];
      final title = (it['sessionTitle'] ?? '').toString().trim();
      final obj = (it['objective'] ?? '').toString().trim();
      if (title.isEmpty || obj.isEmpty) {
        _toast('Included session ${i + 1} is missing required details (Title/Objectives).');
        return;
      }
    }

    // Build sessions payload (1..N)
    final Map<String, dynamic> sessionsOut = {};
    for (int i = 0; i < desiredN; i++) {
      final item = included[i];
      sessionsOut['${i + 1}'] = {
        'sessionNo': i + 1,
        'unitTitle': item['unitTitle'],
        'unitId': item['unitId'],
        'sessionTitle': item['sessionTitle'],
        'sessionId': item['sessionId'],
        'skillType': item['skillType'],
        'objective': item['objective'],
        'content': item['content'],
        'homework': item['homework'],
        'durationMinutes': item['durationMinutes'] ?? 0,
        'sourceCourseId': courseId,
      };
    }

    setState(() => saving = true);
    try {
      await _curriculumRef.child(courseId).set({
        'courseId': courseId,
        'courseTitle': course.title,
        'courseLevelText': course.levelText,
        'courseCategory': course.category,
        'totalSessions': desiredN,
        'updatedAt': ServerValue.timestamp,
        'sessions': sessionsOut,
      });

      await _configRef.child('courses/$courseId').set({
        'enabled': true,
        'title': course.title,
        'totalLessons': desiredN,
        'requireSessionDetails': true,
        'coverageTarget': {
          'weeks': 4,
          'minChoicesPerSession': minChoices,
        },
        'updatedAt': ServerValue.timestamp,
      });

      _toast('Saved & enabled booking ✅');
    } catch (e) {
      _toast('Save failed: $e');
    } finally {
      if (!mounted) return;
      setState(() => saving = false);
    }
  }

  // ========================= UI =========================

  @override
  Widget build(BuildContext context) {
    final course = _selectedCourse();
    final includedCount = _includedCount();
    final missingDetailsCount = _missingDetailsIncludedCount();

    return Scaffold(
      backgroundColor: appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: primaryBlue),
        title: const Text(
          'Booking Setup',
          style: TextStyle(color: primaryBlue, fontWeight: FontWeight.w900),
        ),
        actions: [
          IconButton(
            tooltip: 'Reload courses',
            onPressed: (loadingCourses || saving) ? null : _loadCourses,
            icon: const Icon(Icons.refresh_rounded, color: primaryBlue),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: loadingCourses
          ? const Center(child: CircularProgressIndicator())
          : ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 90),
        children: [
          _HeaderCard(
            title: course?.title ?? 'Select a course',
            subtitle: course == null
                ? 'Choose a published course to prepare booking'
                : [
              if (course.levelText.isNotEmpty) course.levelText,
              if (course.category.isNotEmpty) course.category,
            ].join(' • '),
          ),
          const SizedBox(height: 12),

          _Card(
            title: '1) Course',
            child: Column(
              children: [
                _courseDropdown(),
                const SizedBox(height: 10),
                const _Hint(
                  icon: Icons.info_outline_rounded,
                  text: 'Sessions load from syllabi/<courseId>.\nInclude/exclude, edit details, then enable booking.',
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),

          _Card(
            title: '2) Sessions',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    _ActionButton(
                      label: 'Load syllabus',
                      icon: Icons.download_rounded,
                      busy: loadingSyllabus,
                      onPressed: (loadingSyllabus || saving) ? null : _loadSuggestedFromSyllabus,
                    ),
                    if (suggested.isNotEmpty)
                      _ActionButton(
                        label: 'Auto exclude',
                        icon: Icons.auto_fix_high_rounded,
                        onPressed: saving ? null : _autoExcludeCommon,
                      ),
                  ],
                ),
                const SizedBox(height: 12),

                // ✅ N is automatic now
                _SummaryRow(
                  left: 'Total sessions (auto)',
                  right: suggested.isEmpty ? '—' : '$includedCount',
                  icon: Icons.confirmation_number_rounded,
                ),
                const SizedBox(height: 10),

                _SmallField(
                  controller: minChoicesC,
                  label: 'Min choices per session (within 4 weeks)',
                  hint: '2',
                ),

                const SizedBox(height: 10),

                if (suggested.isEmpty)
                  const _Hint(
                    icon: Icons.tips_and_updates_outlined,
                    text: 'Load syllabus first.\nThen tap any included session to edit details (Title + Objectives required).',
                  )
                else
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _SummaryRow(
                        left: 'Included',
                        right: '$includedCount',
                        icon: Icons.check_circle_rounded,
                      ),
                      const SizedBox(height: 8),
                      _SummaryRow(
                        left: 'Included missing details',
                        right: '$missingDetailsCount',
                        icon: Icons.warning_amber_rounded,
                      ),
                      const SizedBox(height: 12),

                      ...suggested.asMap().entries.map((entry) {
                        final i = entry.key;
                        final item = entry.value;

                        final included = item['include'] == true;
                        final title = (item['sessionTitle'] ?? '').toString().trim();
                        final unitTitle = (item['unitTitle'] ?? '').toString().trim();
                        final skillType = (item['skillType'] ?? '').toString().trim();

                        final missing = included && _isMissingDetails(item);

                        return _SessionRow(
                          index: i + 1,
                          sessionNumber: (item['sessionNumber'] as num?)?.toInt() ?? 0,
                          included: included,
                          title: title.isEmpty ? '(No title)' : title,
                          subtitle: [
                            if (unitTitle.isNotEmpty) unitTitle,
                            if (skillType.isNotEmpty) skillType,
                          ].join(' • '),
                          showWarning: missing,
                          onToggle: (v) => setState(() => suggested[i]['include'] = v),
                          onEdit: () => _editSessionDetails(i),
                        );
                      }).toList(),

                      const SizedBox(height: 12),

                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: actionOrange,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          ),
                          onPressed: saving ? null : _saveCurriculumAndEnable,
                          icon: saving
                              ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                              : const Icon(Icons.check_circle_rounded),
                          label: Text(saving ? 'Saving…' : 'Save & Enable Booking'),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _courseDropdown() {
    if (allCourses.isEmpty) {
      return const _Hint(icon: Icons.warning_amber_rounded, text: 'No published courses found.');
    }

    final safeValue = allCourses.any((x) => x.id == selectedCourseId) ? selectedCourseId : allCourses.first.id;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: uiBorder),
      ),
      child: DropdownButton<String>(
        value: safeValue,
        isExpanded: true,
        underline: const SizedBox.shrink(),
        icon: const Icon(Icons.expand_more_rounded, color: primaryBlue),
        items: allCourses
            .map(
              (c) => DropdownMenuItem(
            value: c.id,
            child: Text(
              c.levelText.isEmpty && c.category.isEmpty
                  ? c.title
                  : '${c.title}  •  ${[
                if (c.levelText.isNotEmpty) c.levelText,
                if (c.category.isNotEmpty) c.category,
              ].join(' • ')}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w900, color: primaryBlue),
            ),
          ),
        )
            .toList(),
        onChanged: (v) {
          setState(() {
            selectedCourseId = v;
            suggested = [];
          });
        },
      ),
    );
  }
}

// ===================== UI Widgets =====================

class _HeaderCard extends StatelessWidget {
  const _HeaderCard({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  static const uiBorder = Color(0xFFD1D9E0);
  static const primaryBlue = Color(0xFF1A2B48);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: uiBorder.withOpacity(0.8)),
      ),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: primaryBlue.withOpacity(0.08),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: primaryBlue.withOpacity(0.12)),
            ),
            child: const Icon(Icons.calendar_month_rounded, color: primaryBlue),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: primaryBlue, fontWeight: FontWeight.w900, fontSize: 16),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Colors.grey.shade700, fontWeight: FontWeight.w700, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.child});

  final String title;
  final Widget child;

  static const uiBorder = Color(0xFFD1D9E0);
  static const primaryBlue = Color(0xFF1A2B48);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: uiBorder.withOpacity(0.8)),
      ),
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

class _Hint extends StatelessWidget {
  const _Hint({required this.icon, required this.text});

  final IconData icon;
  final String text;

  static const uiBorder = Color(0xFFD1D9E0);
  static const appBg = Color(0xFFF4F7F9);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: appBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: uiBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: Colors.grey.shade700, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontWeight: FontWeight.w700, height: 1.25),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.icon,
    this.onPressed,
    this.busy = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool busy;

  static const primaryBlue = Color(0xFF1A2B48);

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: busy
          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
          : Icon(icon, color: primaryBlue),
      label: Text(label, style: const TextStyle(color: primaryBlue, fontWeight: FontWeight.w900)),
      style: OutlinedButton.styleFrom(
        side: BorderSide(color: primaryBlue.withOpacity(0.25)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
    );
  }
}

class _SmallField extends StatelessWidget {
  const _SmallField({required this.controller, required this.label, required this.hint});

  final TextEditingController controller;
  final String label;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        isDense: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: Colors.grey.shade300),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: Colors.grey.shade400),
        ),
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({required this.left, required this.right, required this.icon});

  final String left;
  final String right;
  final IconData icon;

  static const uiBorder = Color(0xFFD1D9E0);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: uiBorder.withOpacity(0.8)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: Colors.grey.shade700),
          const SizedBox(width: 10),
          Expanded(child: Text(left, style: const TextStyle(fontWeight: FontWeight.w900))),
          Text(right, style: TextStyle(fontWeight: FontWeight.w800, color: Colors.grey.shade700)),
        ],
      ),
    );
  }
}

class _SessionRow extends StatelessWidget {
  const _SessionRow({
    required this.index,
    required this.sessionNumber,
    required this.included,
    required this.title,
    required this.subtitle,
    required this.showWarning,
    required this.onToggle,
    required this.onEdit,
  });

  final int index;
  final int sessionNumber;
  final bool included;
  final String title;
  final String subtitle;
  final bool showWarning;
  final ValueChanged<bool> onToggle;
  final VoidCallback onEdit;

  static const uiBorder = Color(0xFFD1D9E0);
  static const primaryBlue = Color(0xFF1A2B48);

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: uiBorder.withOpacity(0.8)),
      ),
      child: Row(
        children: [
          Checkbox(
            value: included,
            onChanged: (v) => onToggle(v == true),
          ),
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: included ? Colors.green.withOpacity(0.10) : Colors.grey.withOpacity(0.10),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: included ? Colors.green.withOpacity(0.25) : Colors.grey.withOpacity(0.25)),
            ),
            child: Center(
              child: Text(
                sessionNumber > 0 ? '#$sessionNumber' : '$index',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  color: included ? Colors.green.shade700 : Colors.grey.shade700,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: InkWell(
              onTap: onEdit,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w900, color: primaryBlue),
                          ),
                        ),
                        if (showWarning)
                          const Padding(
                            padding: EdgeInsets.only(left: 6),
                            child: Icon(Icons.warning_amber_rounded, size: 18, color: Colors.orange),
                          ),
                      ],
                    ),
                    if (subtitle.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontWeight: FontWeight.w700, color: Colors.grey.shade700, fontSize: 12),
                      ),
                    ],
                    const SizedBox(height: 2),
                    Text(
                      'Tap to edit details',
                      style: TextStyle(fontWeight: FontWeight.w700, color: Colors.grey.shade600, fontSize: 11),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          IconButton(
            tooltip: 'Edit',
            onPressed: onEdit,
            icon: const Icon(Icons.edit_rounded, color: primaryBlue),
          ),
        ],
      ),
    );
  }
}

class _Input extends StatelessWidget {
  const _Input({
    required this.controller,
    required this.label,
    required this.hint,
    this.maxLines = 1,
    this.keyboardType,
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final int maxLines;
  final TextInputType? keyboardType;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      maxLines: maxLines,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: Colors.grey.shade300),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: Colors.grey.shade400),
        ),
      ),
    );
  }
}

// ===================== MODEL =====================

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