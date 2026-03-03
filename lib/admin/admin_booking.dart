// ✅ FULL REPLACEMENT: lib/admin/admin_booking.dart
// OPTION 1: Booking is per COURSE (no A0/A1 fixed dropdown)
// UI ONLY upgrade: prettier layout, better spacing, nicer session list, policy moved to a small collapsible section (hidden by default)

import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';

class AdminBookingScreen extends StatefulWidget {
  const AdminBookingScreen({super.key});

  @override
  State<AdminBookingScreen> createState() => _AdminBookingScreenState();
}

class _AdminBookingScreenState extends State<AdminBookingScreen> {
  // ===== colors (match your admin style) =====
  static const primaryBlue = Color(0xFF1A2B48);
  static const actionOrange = Color(0xFFF98D28);
  static const mainText = Color(0xFF2D2D2D);
  static const appBg = Color(0xFFF4F7F9);
  static const uiBorder = Color(0xFFD1D9E0);

  // ===== RTDB refs =====
  final DatabaseReference _configRef = FirebaseDatabase.instance.ref('booking_config');
  final DatabaseReference _coursesRef = FirebaseDatabase.instance.ref('courses');
  final DatabaseReference _syllabiRef = FirebaseDatabase.instance.ref('syllabi');
  final DatabaseReference _curriculumRef = FirebaseDatabase.instance.ref('booking_curriculum');

  // ===== courses =====
  bool loadingCourses = true;
  List<_CourseItem> allCourses = [];
  String? selectedCourseId;

  // ===== builder =====
  bool loadingSyllabus = false;
  bool saving = false;

  List<Map<String, dynamic>> suggested = [];
  final totalSessionsC = TextEditingController(text: '18');

  // UI only
  bool showPolicy = false;

  @override
  void initState() {
    super.initState();
    _loadCourses();
  }

  @override
  void dispose() {
    totalSessionsC.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

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
          final orderIndex =
          (m['order_index'] is num) ? (m['order_index'] as num).toInt() : 999;

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

          out.add({
            'include': true,
            'unitTitle': unitTitle,
            'unitId': unitId,
            'unitOrder': unitOrder,
            'sessionTitle': title,
            'sessionId': id,
            'skillType': skillType,
            'sessionOrder': order,
            'objective': (sess['objective'] ?? '').toString(),
            'content': (sess['content'] ?? '').toString(),
            'homework': (sess['homework'] ?? '').toString(),
            'durationMinutes': sess['durationMinutes'] ?? 0,
          });
        }
      }

      out.sort((a, b) {
        final u = (a['unitOrder'] as num?)?.toInt() ?? 0;
        final uu = (b['unitOrder'] as num?)?.toInt() ?? 0;
        if (u != uu) return u.compareTo(uu);
        final s = (a['sessionOrder'] as num?)?.toInt() ?? 0;
        final ss = (b['sessionOrder'] as num?)?.toInt() ?? 0;
        return s.compareTo(ss);
      });

      setState(() {
        suggested = out;
        final currentN = int.tryParse(totalSessionsC.text.trim()) ?? 0;
        if (currentN <= 0) totalSessionsC.text = out.length.toString();
      });

      _toast('Loaded ${out.length} syllabus sessions ✅');
    } catch (e) {
      _toast('Load failed: $e');
    } finally {
      if (!mounted) return;
      setState(() => loadingSyllabus = false);
    }
  }

  Future<void> _saveCurriculum() async {
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

    int desiredN = int.tryParse(totalSessionsC.text.trim()) ?? 0;
    if (desiredN <= 0) desiredN = 1;

    final included = suggested.where((x) => x['include'] == true).toList();
    if (included.isEmpty) {
      _toast('You excluded everything. Please include at least 1 session.');
      return;
    }

    if (desiredN > included.length) {
      desiredN = included.length;
      totalSessionsC.text = desiredN.toString();
      _toast('Total sessions adjusted to $desiredN (based on included items).');
    }

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
        'durationMinutes': item['durationMinutes'],
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
// Mark course as booking-enabled in booking_config (optional but useful)
      await _configRef.child('courses/$courseId').set({
        'enabled': true,
        'title': course.title,
        'totalLessons': desiredN,
        'updatedAt': ServerValue.timestamp,
      });
      _toast('Saved booking plan for "${course.title}" ✅');
    } catch (e) {
      _toast('Save failed: $e');
    } finally {
      if (!mounted) return;
      setState(() => saving = false);
    }
  }

  Future<void> _saveDefaultPolicy() async {
    setState(() => saving = true);
    try {
      await _configRef.update({
        'policy': {
          'cancelMinHours': 24,
          'noShowConsumesCredit': true,
          'noShowAdvancesProgress': false,
          'openClass': true,
        },
      });
      _toast('Policy saved ✅');
    } catch (e) {
      _toast('Failed: $e');
    } finally {
      if (!mounted) return;
      setState(() => saving = false);
    }
  }

  void _includeOnlyBasic5() {
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

    _toast('Auto-excluded Pre-unit / Mock / Project (you can still adjust).');
  }

  @override
  Widget build(BuildContext context) {
    final course = _selectedCourse();
    final includedCount = suggested.where((x) => x['include'] == true).length;
    final totalLoaded = suggested.length;

    return Scaffold(
      backgroundColor: appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: primaryBlue),
        title: const Text(
          'Booking Plan',
          style: TextStyle(color: primaryBlue, fontWeight: FontWeight.w900),
        ),
        actions: [
          IconButton(
            tooltip: 'Reload courses',
            onPressed: loadingCourses || saving ? null : _loadCourses,
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
          // ========= HERO =========
          _HeroHeader(
            title: course?.title ?? 'Select a course',
            subtitle: course == null
                ? 'Choose a course to build a booking plan'
                : [
              if (course.levelText.isNotEmpty) course.levelText,
              if (course.category.isNotEmpty) course.category,
            ].join(' • '),
          ),
          const SizedBox(height: 12),

          // ========= COURSE PICKER =========
          _SectionCard(
            title: 'Course',
            subtitle: 'Pick any published course from /courses',
            leading: Icons.menu_book_rounded,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _courseDropdown(),
                const SizedBox(height: 10),
                _SoftInfo(
                  icon: Icons.info_outline_rounded,
                  text:
                  'We will load sessions from: syllabi/<courseId>\nThen you can exclude items and set N.',
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // ========= PLAN =========
          _SectionCard(
            title: 'Sessions',
            subtitle: totalLoaded == 0
                ? 'Load syllabus sessions'
                : 'Loaded $totalLoaded • Included $includedCount',
            leading: Icons.layers_rounded,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    _PrimaryOutlineButton(
                      icon: loadingSyllabus ? null : Icons.download_rounded,
                      busy: loadingSyllabus,
                      label: 'Load Syllabus',
                      onPressed: (loadingSyllabus || saving) ? null : _loadSuggestedFromSyllabus,
                    ),
                    if (suggested.isNotEmpty)
                      _PrimaryOutlineButton(
                        icon: Icons.auto_fix_high_rounded,
                        label: 'Auto exclude',
                        onPressed: saving ? null : _includeOnlyBasic5,
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                _NumberField(
                  controller: totalSessionsC,
                  label: 'Total sessions (N)',
                  hint: 'Example: 18',
                ),
                const SizedBox(height: 10),

                if (suggested.isEmpty)
                  _SoftInfo(
                    icon: Icons.tips_and_updates_outlined,
                    text:
                    'Tap “Load Syllabus”, then:\n• uncheck items you don’t want\n• set N\n• save the booking plan',
                  )
                else
                  Column(
                    children: [
                      const SizedBox(height: 6),
                      _MiniStatsRow(
                        left: 'Included',
                        right: '$includedCount',
                        icon: Icons.check_circle_rounded,
                      ),
                      const SizedBox(height: 8),
                      _MiniStatsRow(
                        left: 'Will save to',
                        right: 'booking_curriculum/<courseId>',
                        icon: Icons.storage_rounded,
                        valueMaxLines: 2,
                      ),
                      const SizedBox(height: 10),

                      // nicer list
                      ...suggested.asMap().entries.map((entry) {
                        final i = entry.key;
                        final item = entry.value;

                        final unitTitle = (item['unitTitle'] ?? '').toString().trim();
                        final sessionTitle = (item['sessionTitle'] ?? '').toString().trim();
                        final skillType = (item['skillType'] ?? '').toString().trim();

                        final showUnit = unitTitle.isNotEmpty;
                        final showSkill = skillType.isNotEmpty;

                        return _SessionTile(
                          index: i + 1,
                          included: item['include'] == true,
                          title: sessionTitle.isEmpty ? '(No title)' : sessionTitle,
                          subtitle: [
                            if (showUnit) unitTitle,
                            if (showSkill) skillType,
                          ].join(' • '),
                          onChanged: (v) {
                            setState(() => suggested[i]['include'] = v == true);
                          },
                        );
                      }),

                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: actionOrange,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          onPressed: saving ? null : _saveCurriculum,
                          icon: saving
                              ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                              : const Icon(Icons.check_circle_rounded),
                          label: Text(saving ? 'Saving…' : 'Save Booking Plan'),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),

          const SizedBox(height: 12),

          // ========= POLICY (COLLAPSIBLE) =========
          _SectionCard(
            title: 'Policy',
            subtitle: showPolicy ? 'Visible' : 'Hidden',
            leading: Icons.policy_rounded,
            trailing: IconButton(
              tooltip: showPolicy ? 'Hide' : 'Show',
              onPressed: () => setState(() => showPolicy = !showPolicy),
              icon: Icon(
                showPolicy ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                color: primaryBlue,
              ),
            ),
            child: AnimatedCrossFade(
              duration: const Duration(milliseconds: 200),
              crossFadeState:
              showPolicy ? CrossFadeState.showFirst : CrossFadeState.showSecond,
              firstChild: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _SoftInfo(
                    icon: Icons.rule_folder_outlined,
                    text:
                    'Default rules:\n• Cancel only if ≥ 24h\n• No-show consumes credit\n• No-show does NOT advance progress\n• Open class enabled',
                  ),
                  const SizedBox(height: 10),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: primaryBlue,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    onPressed: saving ? null : _saveDefaultPolicy,
                    icon: const Icon(Icons.save_rounded),
                    label: const Text('Save Default Policy'),
                  ),
                ],
              ),
              secondChild: _SoftInfo(
                icon: Icons.visibility_off_outlined,
                text: 'Policy is hidden. Tap the arrow to show it.',
              ),
            ),
          ),

          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _courseDropdown() {
    if (allCourses.isEmpty) {
      return _SoftInfo(
        icon: Icons.warning_amber_rounded,
        text: 'No published courses found.',
      );
    }

    final safeValue =
    allCourses.any((x) => x.id == selectedCourseId) ? selectedCourseId : allCourses.first.id;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: uiBorder),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 8,
            offset: const Offset(0, 4),
          )
        ],
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
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: primaryBlue.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: primaryBlue.withOpacity(0.12)),
                  ),
                  child: const Icon(Icons.school_rounded, color: primaryBlue, size: 18),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        c.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          color: primaryBlue,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        [
                          if (c.levelText.isNotEmpty) c.levelText,
                          if (c.category.isNotEmpty) c.category,
                        ].join(' • '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 11,
                          color: mainText.withOpacity(0.65),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
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

// ===================== UI PIECES =====================

class _HeroHeader extends StatelessWidget {
  final String title;
  final String subtitle;

  const _HeroHeader({required this.title, required this.subtitle});

  static const primaryBlue = Color(0xFF1A2B48);
  static const uiBorder = Color(0xFFD1D9E0);

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: uiBorder.withOpacity(0.8)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 10,
            offset: const Offset(0, 6),
          )
        ],
      ),
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
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
                  style: const TextStyle(
                    color: primaryBlue,
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.grey.shade700,
                    fontWeight: FontWeight.w700,
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
}

class _SectionCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData leading;
  final Widget child;
  final Widget? trailing;

  const _SectionCard({
    required this.title,
    required this.subtitle,
    required this.leading,
    required this.child,
    this.trailing,
  });

  static const primaryBlue = Color(0xFF1A2B48);
  static const uiBorder = Color(0xFFD1D9E0);

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: uiBorder.withOpacity(0.8)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 10,
            offset: const Offset(0, 6),
          )
        ],
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: primaryBlue.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: primaryBlue.withOpacity(0.12)),
                ),
                child: Icon(leading, color: primaryBlue, size: 20),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: primaryBlue,
                        fontWeight: FontWeight.w900,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.grey.shade700,
                        fontWeight: FontWeight.w700,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _SoftInfo extends StatelessWidget {
  final IconData icon;
  final String text;

  const _SoftInfo({required this.icon, required this.text});

  static const appBg = Color(0xFFF4F7F9);
  static const uiBorder = Color(0xFFD1D9E0);

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

class _PrimaryOutlineButton extends StatelessWidget {
  final IconData? icon;
  final String label;
  final VoidCallback? onPressed;
  final bool busy;

  const _PrimaryOutlineButton({
    required this.label,
    this.icon,
    this.onPressed,
    this.busy = false,
  });

  static const primaryBlue = Color(0xFF1A2B48);

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: busy
          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
          : Icon(icon ?? Icons.circle, color: primaryBlue),
      label: Text(
        label,
        style: const TextStyle(color: primaryBlue, fontWeight: FontWeight.w900),
      ),
      style: OutlinedButton.styleFrom(
        side: BorderSide(color: primaryBlue.withOpacity(0.25)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
    );
  }
}

class _NumberField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String hint;

  const _NumberField({
    required this.controller,
    required this.label,
    required this.hint,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: Colors.grey.shade300),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: Colors.grey.shade400),
        ),
      ),
    );
  }
}

class _MiniStatsRow extends StatelessWidget {
  final String left;
  final String right;
  final IconData icon;
  final int valueMaxLines;

  const _MiniStatsRow({
    required this.left,
    required this.right,
    required this.icon,
    this.valueMaxLines = 1,
  });

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
          Expanded(
            child: Text(
              left,
              style: const TextStyle(fontWeight: FontWeight.w900),
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              right,
              maxLines: valueMaxLines,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: Colors.grey.shade700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SessionTile extends StatelessWidget {
  final int index;
  final bool included;
  final String title;
  final String subtitle;
  final ValueChanged<bool?> onChanged;

  const _SessionTile({
    required this.index,
    required this.included,
    required this.title,
    required this.subtitle,
    required this.onChanged,
  });

  static const uiBorder = Color(0xFFD1D9E0);

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: uiBorder.withOpacity(0.8)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.02),
            blurRadius: 8,
            offset: const Offset(0, 4),
          )
        ],
      ),
      child: CheckboxListTile(
        value: included,
        onChanged: onChanged,
        controlAffinity: ListTileControlAffinity.leading,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        title: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: included ? Colors.green.withOpacity(0.10) : Colors.grey.withOpacity(0.10),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: included ? Colors.green.withOpacity(0.25) : Colors.grey.withOpacity(0.25),
                ),
              ),
              child: Center(
                child: Text(
                  '$index',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: included ? Colors.green.shade700 : Colors.grey.shade700,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
            ),
          ],
        ),
        subtitle: subtitle.isEmpty
            ? null
            : Padding(
          padding: const EdgeInsets.only(left: 44, top: 6),
          child: Text(
            subtitle,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: Colors.grey.shade700,
            ),
          ),
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