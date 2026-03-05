import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

/// ----------------------------
/// Course Syllabus Screen
/// ----------------------------
/// Data path:
///   syllabi/{courseId}
///
/// Structure:
///   {
///     courseId: "...",
///     updatedAt: <server timestamp>,
///     units: [
///       {
///         id: "...",
///         title: "...",
///         otherTitle: "...",     // name in brackets
///         description: "...",
///         order: 1,
///         sessions: [
///           {
///             id: "...",
///             title: "...",
///             skillType: "Listening|Speaking|Reading|Writing|Grammar|Project",
///             objective: "...",
///             content: "...",
///             homework: "...",   // optional
///             ///             sessionNumber: 1    // ✅ NEW
///             durationMinutes: 45,
///             order: 1
///           }
///         ]
///       }
///     ]
///   }
///

class CourseSyllabusScreen extends StatefulWidget {
  const CourseSyllabusScreen({
    super.key,
    required this.courseId,
    required this.courseTitle,
    required this.variantKey,
  });

  final String courseId;
  final String courseTitle;

  /// One of: recorded, live, in_class, online
  final String variantKey;

  @override
  State<CourseSyllabusScreen> createState() => _CourseSyllabusScreenState();
}

class _CourseSyllabusScreenState extends State<CourseSyllabusScreen> {
  final _db = FirebaseDatabase.instance;

  DatabaseReference get _syllabusRef =>
      _db.ref('syllabi').child(widget.courseId).child(widget.variantKey);

  bool _loading = true;
  bool _saving = false;

  List<SyllabusUnit> _units = [];
  final Map<String, bool> _unitExpanded = {}; // unitId -> true/false

  @override
  void initState() {
    super.initState();
    _loadSyllabus();
  }

  Future<void> _loadSyllabus() async {
    setState(() => _loading = true);
    try {
      // 1) Try new per-variant location first
      final snap = await _syllabusRef.get();
      dynamic v = snap.value;

      // If this variant doesn't exist yet, create a placeholder flag in the course node
      if (v == null) {
        await _db
            .ref('courses')
            .child(widget.courseId)
            .child('syllabi_flags')
            .child(widget.variantKey)
            .set(false);
      }

      if (v is Map && v['units'] is List) {
        final rawUnits = (v['units'] as List).whereType<Map>().toList();
        final units = rawUnits.map(SyllabusUnit.fromMap).toList();

        // ensure order sorting
        units.sort((a, b) => a.order.compareTo(b.order));
        for (final u in units) {
          u.sessions.sort((a, b) => a.order.compareTo(b.order));
        }
        _units = units;
        _ensureSessionNumbers();

      } else {
        _units = [];
      }
    } catch (_) {
      _units = [];
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  int get _totalSessions =>
      _units.fold<int>(0, (sum, u) => sum + u.sessions.length);


  void _ensureSessionNumbers() {
    // Ensure correct ordering before numbering
    _units.sort((a, b) => a.order.compareTo(b.order));
    for (final u in _units) {
      u.sessions.sort((a, b) => a.order.compareTo(b.order));
    }

    int n = 1;
    for (int ui = 0; ui < _units.length; ui++) {
      final u = _units[ui];
      final sessions = <SyllabusSession>[];

      for (int si = 0; si < u.sessions.length; si++) {
        final s = u.sessions[si];
        sessions.add(s.copyWith(sessionNumber: n));
        n++;
      }

      _units[ui] = u.copyWith(sessions: sessions);
    }
  }

  Future<void> _saveSyllabus() async {
    setState(() => _saving = true);
    try {
      // normalize orders before saving
      for (int i = 0; i < _units.length; i++) {
        _units[i] = _units[i].copyWith(order: i + 1);
        for (int j = 0; j < _units[i].sessions.length; j++) {
          _units[i].sessions[j] = _units[i].sessions[j].copyWith(order: j + 1);
        }
      }

      _ensureSessionNumbers();

      // 1) Read course meta (code/title/duration) from the "courses/{courseId}" node
      final courseSnap = await _db.ref('courses').child(widget.courseId).get();
      final courseMap = (courseSnap.value is Map) ? (courseSnap.value as Map) : {};

      final courseCode = (courseMap['course_code'] ?? '').toString();
      final courseTitle = (courseMap['title'] ?? widget.courseTitle).toString();
      final courseDuration = (courseMap['duration'] ?? '').toString();

// 2) Save syllabus INCLUDING those fields
      final payload = {
        'courseId': widget.courseId,
        'courseCode': courseCode,   // <- new
        'title': courseTitle,       // <- new
        'duration': courseDuration, // <- new
        'updatedAt': ServerValue.timestamp,
        'units': _units
            .map((u) => u.toMap(
          includeRecordedExtras: widget.variantKey == 'recorded',
          includeOnlineExtras: widget.variantKey == 'online',
        ))
            .toList(),
      };

      await _syllabusRef.set(payload);

// ✅ write a quick “tick flag” so Admin list can show ✅ without scanning syllabi
      await _db
          .ref('courses')
          .child(widget.courseId)
          .child('syllabi_flags')
          .child(widget.variantKey)
          .set(true);


      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Syllabus saved ✅')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Save failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ----------------------------
  // Unit actions
  // ----------------------------

  Future<void> _addUnit() async {
    final res = await showModalBottomSheet<_UnitDraft>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _UnitEditorSheet(
        title: 'Add Unit',
        initial: _UnitDraft(title: '', otherTitle: '', description: ''),
      ),
    );

    if (res == null) return;

    final newUnit = SyllabusUnit(
      id: _newId(),
      title: res.title.trim(),
      otherTitle: res.otherTitle.trim(),
      description: res.description.trim(),
      order: _units.length + 1,
      sessions: [],
    );

    setState(() => _units = [..._units, newUnit]);
  }

  Future<void> _editUnit(int unitIndex) async {
    final u = _units[unitIndex];
    final res = await showModalBottomSheet<_UnitDraft>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _UnitEditorSheet(
        title: 'Edit Unit',
        initial: _UnitDraft(
          title: u.title,
          otherTitle: u.otherTitle,
          description: u.description,
        ),
      ),
    );

    if (res == null) return;

    setState(() {
      final updated = u.copyWith(
        title: res.title.trim(),
        otherTitle: res.otherTitle.trim(),
        description: res.description.trim(),
      );
      final next = [..._units];
      next[unitIndex] = updated;
      _units = next;
    });
  }

  Future<void> _deleteUnit(int unitIndex) async {
    final ok = await _confirm(
      title: 'Delete Unit?',
      message: 'This will delete the unit and all its sessions.',
      confirmText: 'Delete',
      danger: true,
    );
    if (!ok) return;

    setState(() {
      final next = [..._units]..removeAt(unitIndex);
      _units = next;
    });
  }

  void _moveUnit(int from, int to) {
    setState(() {
      final next = [..._units];
      final item = next.removeAt(from);
      next.insert(to, item);
      _units = next;
    });
  }

  // ----------------------------
  // Session actions
  // ----------------------------

  Future<void> _addSession(int unitIndex) async {
    final res = await showModalBottomSheet<_SessionDraft>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _SessionEditorSheet(
        title: 'Add Session',
        isRecorded: widget.variantKey.trim().toLowerCase() == 'recorded',
        initial: _SessionDraft(
          title: '',
          skillType: SkillType.listening,
          objective: '',
          content: '',
          homework: '',
          durationMinutes: 45, // default
          videoUrl: '',
          videoThumbnailUrl: '',
          materialsUrl: '',
        ),
      ),
    );

    if (res == null) return;

    final unit = _units[unitIndex];
    final newSession = SyllabusSession(
      id: _newId(),
      title: res.title.trim(),
      skillType: res.skillType,
      objective: res.objective.trim(),
      content: res.content.trim(),
      homework: res.homework.trim(),
      durationMinutes: res.durationMinutes,
      order: unit.sessions.length + 1,
      sessionNumber: _totalSessions + 1, // temporary; _ensureSessionNumbers() will finalize
      videoUrl: res.videoUrl.trim(),
      videoThumbnailUrl: res.videoThumbnailUrl.trim(),
      materialsUrl: res.materialsUrl.trim(),
    );

    setState(() {
      final next = [..._units];
      next[unitIndex] = unit.copyWith(sessions: [...unit.sessions, newSession]);
      _units = next;
    });
  }

  Future<void> _editSession(int unitIndex, int sessionIndex) async {
    final unit = _units[unitIndex];
    final s = unit.sessions[sessionIndex];

    final res = await showModalBottomSheet<_SessionDraft>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _SessionEditorSheet(
        title: 'Edit Session',
        isRecorded: widget.variantKey.trim().toLowerCase() == 'recorded',
        initial: _SessionDraft(
          title: s.title,
          skillType: s.skillType,
          objective: s.objective,
          content: s.content,
          homework: s.homework,
          durationMinutes: s.durationMinutes,
          videoUrl: s.videoUrl,
          videoThumbnailUrl: s.videoThumbnailUrl,
          materialsUrl: s.materialsUrl,
        ),
      ),
    );

    if (res == null) return;

    final updated = s.copyWith(
      title: res.title.trim(),
      skillType: res.skillType,
      objective: res.objective.trim(),
      content: res.content.trim(),
      homework: res.homework.trim(),
      durationMinutes: res.durationMinutes,
      videoUrl: res.videoUrl.trim(),
      videoThumbnailUrl: res.videoThumbnailUrl.trim(),
      materialsUrl: res.materialsUrl.trim(),
    );

    setState(() {
      final sessions = [...unit.sessions];
      sessions[sessionIndex] = updated;
      final nextUnits = [..._units];
      nextUnits[unitIndex] = unit.copyWith(sessions: sessions);
      _units = nextUnits;
    });
  }

  Future<void> _deleteSession(int unitIndex, int sessionIndex) async {
    final ok = await _confirm(
      title: 'Delete Session?',
      message: 'This will delete this session.',
      confirmText: 'Delete',
      danger: true,
    );
    if (!ok) return;

    setState(() {
      final unit = _units[unitIndex];
      final sessions = [...unit.sessions]..removeAt(sessionIndex);
      final nextUnits = [..._units];
      nextUnits[unitIndex] = unit.copyWith(sessions: sessions);
      _units = nextUnits;
    });
  }

  void _moveSession(int unitIndex, int from, int to) {
    setState(() {
      final unit = _units[unitIndex];
      final sessions = [...unit.sessions];
      final item = sessions.removeAt(from);
      sessions.insert(to, item);

      final nextUnits = [..._units];
      nextUnits[unitIndex] = unit.copyWith(sessions: sessions);
      _units = nextUnits;
    });
  }

  // ----------------------------
  // UI
  // ----------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F7F9),
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Syllabus',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 16,
                color: Color(0xFF1A2B48),
              ),
            ),
            Text(
              '${widget.courseTitle} • ${_variantLabel(widget.variantKey)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 12,
                color: Colors.black.withOpacity(0.6),
              ),
            ),
          ],
        ),

        iconTheme: const IconThemeData(color: Color(0xFF1A2B48)),
        actions: [
          IconButton(
            tooltip: 'Reload',
            onPressed: _loading ? null : _loadSyllabus,
            icon: const Icon(Icons.refresh),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8.0),
            child: FilledButton.icon(
              onPressed: (_saving || _loading) ? null : _saveSyllabus,
              icon: _saving
                  ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
                  : const Icon(Icons.save),
              label: Text(_saving ? 'Saving…' : 'Save'),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _loading ? null : _addUnit,
        icon: const Icon(Icons.add),
        label: const Text('Add Unit'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _units.isEmpty
          ? _EmptyState(
        onAddUnit: _addUnit,
        courseTitle: widget.courseTitle,
      )
          : Column(
        children: [
          _HeaderStats(units: _units.length, sessions: _totalSessions),
          Expanded(
            child: ReorderableListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 90),
              itemCount: _units.length,
              onReorder: (oldIndex, newIndex) {
                if (newIndex > oldIndex) newIndex -= 1;
                _moveUnit(oldIndex, newIndex);
              },
              itemBuilder: (context, unitIndex) {
                final unit = _units[unitIndex];
                return _UnitCard(
                  key: ValueKey(unit.id),
                  unitNumber: unitIndex + 1,
                  unit: unit,

                  // ✅ NEW (collapse/expand)
                  isExpanded: _isExpanded(unit.id),
                  onToggleExpanded: () => _toggleExpanded(unit.id),

                  onEdit: () => _editUnit(unitIndex),
                  onDelete: () => _deleteUnit(unitIndex),
                  onAddSession: () => _addSession(unitIndex),
                  onReorderSession: (oldI, newI) {
                    if (newI > oldI) newI -= 1;
                    _moveSession(unitIndex, oldI, newI);
                  },
                  onEditSession: (sessionIndex) =>
                      _editSession(unitIndex, sessionIndex),
                  onDeleteSession: (sessionIndex) =>
                      _deleteSession(unitIndex, sessionIndex),
                );

              },
            ),
          ),
        ],
      ),
    );
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String confirmText,
    bool danger = false,
  }) async {
    return (await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: danger ? Colors.red : null,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: Text(confirmText),
          ),
        ],
      ),
    )) ??
        false;
  }

  String _newId() => DateTime.now().microsecondsSinceEpoch.toString();
  bool _isExpanded(String unitId) => _unitExpanded[unitId] ?? true;

  String _variantLabel(String key) {
    switch (key.trim().toLowerCase()) {
      case 'recorded':
        return 'Recorded';
      case 'live':
        return 'Live';
      case 'in_class':
        return 'In-Class';
      case 'online':
        return 'Online';
      default:
        return key;
    }
  }

  void _toggleExpanded(String unitId) {
    setState(() => _unitExpanded[unitId] = !(_unitExpanded[unitId] ?? true));
  }

}

/// ----------------------------
/// Widgets
/// ----------------------------

class _HeaderStats extends StatelessWidget {
  const _HeaderStats({required this.units, required this.sessions});
  final int units;
  final int sessions;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(
        children: [
          _Pill(label: '$units Units'),
          const SizedBox(width: 8),
          _Pill(label: '$sessions Sessions'),
          const Spacer(),
          Text(
            'Drag units to reorder',
            style: TextStyle(color: Colors.black.withOpacity(0.55)),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onAddUnit, required this.courseTitle});
  final VoidCallback onAddUnit;
  final String courseTitle;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Card(
        elevation: 0,
        color: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        margin: const EdgeInsets.all(16),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.menu_book_outlined, size: 42, color: Color(0xFF1A2B48)),
              const SizedBox(height: 10),
              Text(
                'No syllabus yet',
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 16,
                  color: Color(0xFF1A2B48),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Create the syllabus for "$courseTitle" by adding your first unit.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.black.withOpacity(0.7)),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: onAddUnit,
                icon: const Icon(Icons.add),
                label: const Text('Add Unit'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _UnitCard extends StatelessWidget {
  const _UnitCard({
    super.key,
    required this.unitNumber,
    required this.unit,
    required this.isExpanded,
    required this.onToggleExpanded,
    required this.onEdit,
    required this.onDelete,
    required this.onAddSession,
    required this.onReorderSession,
    required this.onEditSession,
    required this.onDeleteSession,
  });


  final int unitNumber;
  final SyllabusUnit unit;
  final bool isExpanded;
  final VoidCallback onToggleExpanded;

  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onAddSession;

  final void Function(int oldIndex, int newIndex) onReorderSession;
  final void Function(int sessionIndex) onEditSession;
  final void Function(int sessionIndex) onDeleteSession;

  @override
  Widget build(BuildContext context) {
    final title = unit.otherTitle.trim().isEmpty
        ? unit.title
        : '${unit.title} (${unit.otherTitle})';

    return Card(
      key: key,
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF1A2B48).withOpacity(0.08), // light blue bar
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  _Pill(label: 'Unit $unitNumber'),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      title.isEmpty ? '(Untitled unit)' : title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF1A2B48),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: isExpanded ? 'Collapse' : 'Expand',
                    onPressed: onToggleExpanded,
                    icon: Icon(isExpanded ? Icons.expand_less : Icons.expand_more),
                  ),

                  PopupMenuButton<String>(
                    onSelected: (v) {
                      if (v == 'edit') onEdit();
                      if (v == 'delete') onDelete();
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'edit', child: Text('Edit unit')),
                      PopupMenuDivider(),
                      PopupMenuItem(value: 'delete', child: Text('Delete unit')),
                    ],
                  ),
                ],
              ),
            ),

            if (unit.description.trim().isNotEmpty) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  unit.description,
                  style: TextStyle(color: Colors.black.withOpacity(0.65)),
                ),
              ),
            ],
            const SizedBox(height: 10),

            Row(
              children: [
                Text(
                  '${unit.sessions.length} sessions',
                  style: TextStyle(color: Colors.black.withOpacity(0.55)),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: onAddSession,
                  icon: const Icon(Icons.add),
                  label: const Text('Add session'),
                ),
              ],
            ),

            if (!isExpanded)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'Collapsed • ${unit.sessions.length} sessions',
                    style: TextStyle(color: Colors.black.withOpacity(0.55)),
                  ),
                ),
              )
            else if (unit.sessions.isEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'No sessions yet. Add your first session.',
                    style: TextStyle(color: Colors.black.withOpacity(0.55)),
                  ),
                ),
              )
            else
              ReorderableListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                buildDefaultDragHandles: false,
                itemCount: unit.sessions.length,
                onReorder: onReorderSession,
                itemBuilder: (context, i) {
                  final s = unit.sessions[i];
                  return ListTile(
                    key: ValueKey(s.id),
                    leading: ReorderableDragStartListener(
                      index: i,
                      child: const Icon(Icons.drag_handle),
                    ),
                    title: Text(
                      'Session ${s.sessionNumber <= 0 ? (i + 1) : s.sessionNumber} • ${s.title.isEmpty ? '(Untitled session)' : s.title}',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    subtitle: Text(
                      '${s.skillType.label} • ${s.durationMinutes} min\nObjective: ${s.objective.isEmpty ? '(missing)' : s.objective}',
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: PopupMenuButton<String>(
                      onSelected: (v) {
                        if (v == 'edit') onEditSession(i);
                        if (v == 'delete') onDeleteSession(i);
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'edit', child: Text('Edit')),
                        PopupMenuDivider(),
                        PopupMenuItem(value: 'delete', child: Text('Delete')),
                      ],
                    ),
                  );
                },
              ),

          ],
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFF4F7F9),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: Color(0xFF1A2B48),
        ),
      ),
    );
  }
}

/// ----------------------------
/// Bottom sheets (editors)
/// ----------------------------

class _UnitDraft {
  _UnitDraft({
    required this.title,
    required this.otherTitle,
    required this.description,
  });

  final String title;
  final String otherTitle;
  final String description;
}

class _UnitEditorSheet extends StatefulWidget {
  const _UnitEditorSheet({required this.title, required this.initial});
  final String title;
  final _UnitDraft initial;

  @override
  State<_UnitEditorSheet> createState() => _UnitEditorSheetState();
}

class _UnitEditorSheetState extends State<_UnitEditorSheet> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController titleC;
  late final TextEditingController otherTitleC;
  late final TextEditingController descC;

  @override
  void initState() {
    super.initState();
    titleC = TextEditingController(text: widget.initial.title);
    otherTitleC = TextEditingController(text: widget.initial.otherTitle);
    descC = TextEditingController(text: widget.initial.description);
  }

  @override
  void dispose() {
    titleC.dispose();
    otherTitleC.dispose();
    descC.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(14),
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
                const SizedBox(height: 12),
                TextFormField(
                  controller: titleC,
                  decoration: const InputDecoration(
                    labelText: 'Unit name *',
                    hintText: 'Example: Unit 1: Introductions',
                    filled: true,
                  ),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: otherTitleC,
                  decoration: const InputDecoration(
                    labelText: 'Other name (in brackets)',
                    hintText: 'Example: Theme / Module / Part',
                    filled: true,
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: descC,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Unit description',
                    hintText: 'Optional description',
                    filled: true,
                  ),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () {
                      if (!_form.currentState!.validate()) return;
                      Navigator.pop(
                        context,
                        _UnitDraft(
                          title: titleC.text,
                          otherTitle: otherTitleC.text,
                          description: descC.text,
                        ),
                      );
                    },
                    child: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('Done'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SessionDraft {
  _SessionDraft({
    required this.title,
    required this.skillType,
    required this.objective,
    required this.content,
    required this.homework,
    required this.durationMinutes,
    this.videoUrl = '',
    this.videoThumbnailUrl = '',
    this.materialsUrl = '',
  });

  final String title;
  final SkillType skillType;
  final String objective;
  final String content;
  final String homework;
  final int durationMinutes;

  final String videoUrl;
  final String videoThumbnailUrl;

  final String materialsUrl;
}

class _SessionEditorSheet extends StatefulWidget {
  const _SessionEditorSheet({
    required this.title,
    required this.initial,
    required this.isRecorded,
  });

  final String title;
  final _SessionDraft initial;
  final bool isRecorded;

  @override
  State<_SessionEditorSheet> createState() => _SessionEditorSheetState();
}

class _SessionEditorSheetState extends State<_SessionEditorSheet> {
  final _form = GlobalKey<FormState>();

  late final TextEditingController titleC;
  late final TextEditingController objectiveC;
  late final TextEditingController contentC;
  late final TextEditingController homeworkC;
  late final TextEditingController durationC;
  late final TextEditingController videoUrlC;
  late final TextEditingController videoThumbC;
  late final TextEditingController materialsUrlC;
  SkillType _skill = SkillType.listening;

  @override
  void initState() {
    super.initState();
    titleC = TextEditingController(text: widget.initial.title);
    objectiveC = TextEditingController(text: widget.initial.objective);
    contentC = TextEditingController(text: widget.initial.content);
    homeworkC = TextEditingController(text: widget.initial.homework);
    durationC = TextEditingController(text: widget.initial.durationMinutes.toString());
    videoUrlC = TextEditingController(text: widget.initial.videoUrl);
    videoThumbC = TextEditingController(text: widget.initial.videoThumbnailUrl);
    materialsUrlC = TextEditingController(text: widget.initial.materialsUrl);
    _skill = widget.initial.skillType;
  }

  @override
  void dispose() {
    titleC.dispose();
    objectiveC.dispose();
    contentC.dispose();
    homeworkC.dispose();
    durationC.dispose();
    videoUrlC.dispose();
    videoThumbC.dispose();
    materialsUrlC.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(14),
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
                const SizedBox(height: 12),

                TextFormField(
                  controller: titleC,
                  decoration: const InputDecoration(
                    labelText: 'Session title *',
                    hintText: 'Example: Listening – Greetings',
                    filled: true,
                  ),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                ),

                const SizedBox(height: 12),

                DropdownButtonFormField<SkillType>(
                  value: _skill,
                  items: SkillType.values
                      .map((s) => DropdownMenuItem(value: s, child: Text(s.label)))
                      .toList(),
                  onChanged: (v) => setState(() => _skill = v ?? _skill),
                  decoration: const InputDecoration(
                    labelText: 'Skill type',
                    filled: true,
                  ),
                ),

                const SizedBox(height: 12),

                TextFormField(
                  controller: objectiveC,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Lesson objective *',
                    hintText: 'By the end of this session, students will be able to…',
                    filled: true,
                  ),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Objective is required' : null,
                ),

                const SizedBox(height: 12),

                TextFormField(
                  controller: durationC,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Estimated duration (minutes)',
                    hintText: 'Example: 45',
                    filled: true,
                  ),
                  validator: (v) {
                    final t = (v ?? '').trim();
                    if (t.isEmpty) return 'Required';
                    final n = int.tryParse(t);
                    if (n == null) return 'Must be a number';
                    if (n <= 0) return 'Must be > 0';
                    return null;
                  },
                ),

                const SizedBox(height: 12),

                TextFormField(
                  controller: contentC,
                  maxLines: 6,
                  decoration: const InputDecoration(
                    labelText: 'Lesson content',
                    hintText: 'Optional: instructions, links, text, activities…',
                    filled: true,
                  ),
                ),

                const SizedBox(height: 12),

                TextFormField(
                  controller: homeworkC,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    labelText: 'Homework / Quiz (optional)',
                    hintText: 'Optional: questions, tasks, exercises…',
                    filled: true,
                  ),
                ),
                if (widget.isRecorded) ...[
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: videoUrlC,
                    decoration: const InputDecoration(
                      labelText: 'Recorded video URL',
                      hintText: 'https://...',
                      filled: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: videoThumbC,
                    decoration: const InputDecoration(
                      labelText: 'Video thumbnail URL',
                      hintText: 'https://...',
                      filled: true,
                    ),
                  ),
                ],
                if (!widget.isRecorded) ...[
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: materialsUrlC,
                    decoration: const InputDecoration(
                      labelText: 'Materials link (PowerPoint/Drive)',
                      hintText: 'https://...',
                      filled: true,
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () {
                      if (!_form.currentState!.validate()) return;

                      Navigator.pop(
                        context,
                        _SessionDraft(
                          title: titleC.text,
                          skillType: _skill,
                          objective: objectiveC.text,
                          content: contentC.text,
                          homework: homeworkC.text,
                          durationMinutes: int.parse(durationC.text.trim()),
                          videoUrl: widget.isRecorded ? videoUrlC.text.trim() : '',
                          videoThumbnailUrl: widget.isRecorded ? videoThumbC.text.trim() : '',
                          materialsUrl: widget.isRecorded ? '' : materialsUrlC.text.trim(),
                        ),
                      );
                    },
                    child: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('Done'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// ----------------------------
/// Models
/// ----------------------------

enum SkillType { listening, speaking, reading, writing, grammar, project }

extension SkillTypeX on SkillType {
  String get label {
    switch (this) {
      case SkillType.listening:
        return 'Listening';
      case SkillType.speaking:
        return 'Speaking';
      case SkillType.reading:
        return 'Reading';
      case SkillType.writing:
        return 'Writing';
      case SkillType.grammar:
        return 'Grammar';
      case SkillType.project:
        return 'Project';
    }
  }

  static SkillType fromString(String? s) {
    final v = (s ?? '').toLowerCase().trim();
    switch (v) {
      case 'speaking':
        return SkillType.speaking;
      case 'reading':
        return SkillType.reading;
      case 'writing':
        return SkillType.writing;
      case 'grammar':
        return SkillType.grammar;
      case 'project':
        return SkillType.project;
      case 'listening':
      default:
        return SkillType.listening;
    }
  }
}

class SyllabusUnit {
  SyllabusUnit({
    required this.id,
    required this.title,
    required this.otherTitle,
    required this.description,
    required this.order,
    required this.sessions,
  });

  final String id;
  final String title;
  final String otherTitle;
  final String description;
  final int order;
  final List<SyllabusSession> sessions;

  SyllabusUnit copyWith({
    String? title,
    String? otherTitle,
    String? description,
    int? order,
    List<SyllabusSession>? sessions,
  }) {
    return SyllabusUnit(
      id: id,
      title: title ?? this.title,
      otherTitle: otherTitle ?? this.otherTitle,
      description: description ?? this.description,
      order: order ?? this.order,
      sessions: sessions ?? this.sessions,
    );
  }

  Map<String, dynamic> toMap({
    required bool includeRecordedExtras,
    required bool includeOnlineExtras,
  }) {
    return {
      'id': id,
      'title': title,
      'otherTitle': otherTitle,
      'description': description,
      'order': order,
      'sessions': sessions
          .map((s) => s.toMap(
        includeRecordedExtras: includeRecordedExtras,
        includeOnlineExtras: includeOnlineExtras,
      ))
          .toList(),
    };
  }

  factory SyllabusUnit.fromMap(Map m) {
    final rawSessions = (m['sessions'] is List) ? (m['sessions'] as List) : [];
    final sessions = rawSessions
        .whereType<Map>()
        .map((x) => SyllabusSession.fromMap(x))
        .toList();

    return SyllabusUnit(
      id: (m['id'] ?? '').toString(),
      title: (m['title'] ?? '').toString(),
      otherTitle: (m['otherTitle'] ?? '').toString(),
      description: (m['description'] ?? '').toString(),
      order: (m['order'] is num) ? (m['order'] as num).toInt() : (int.tryParse('${m['order']}') ?? 0),
      sessions: sessions,
    );
  }
}

class SyllabusSession {

  SyllabusSession({
    required this.id,
    required this.title,
    required this.skillType,
    required this.objective,
    required this.content,
    required this.homework,
    required this.durationMinutes,
    required this.order,
    required this.sessionNumber,
    this.videoUrl = '',
    this.videoThumbnailUrl = '',
    this.materialsUrl = '',
  });


  final String id;
  final String title;
  final SkillType skillType;
  final String objective;
  final String content;
  final String homework; // optional
  final int durationMinutes; // required
  final int order;

  // ✅ NEW
  final int sessionNumber;
// ✅ Recorded-only extras (optional)
  final String videoUrl;
  final String videoThumbnailUrl;
  final String materialsUrl;
  SyllabusSession copyWith({
    String? title,
    SkillType? skillType,
    String? objective,
    String? content,
    String? homework,
    int? durationMinutes,
    int? order,
    int? sessionNumber,
    String? videoUrl,
    String? videoThumbnailUrl,
    String? materialsUrl,
  }) {
    return SyllabusSession(
      id: id,
      title: title ?? this.title,
      skillType: skillType ?? this.skillType,
      objective: objective ?? this.objective,
      content: content ?? this.content,
      homework: homework ?? this.homework,
      durationMinutes: durationMinutes ?? this.durationMinutes,
      order: order ?? this.order,
      sessionNumber: sessionNumber ?? this.sessionNumber,
      videoUrl: videoUrl ?? this.videoUrl,
      videoThumbnailUrl: videoThumbnailUrl ?? this.videoThumbnailUrl,
      materialsUrl: materialsUrl ?? this.materialsUrl,
    );
  }

  Map<String, dynamic> toMap({
    required bool includeRecordedExtras,
    required bool includeOnlineExtras,
  }) {
    final map = {
      'id': id,
      'title': title,
      'skillType': skillType.label,
      'objective': objective,
      'content': content,
      'homework': homework,
      'durationMinutes': durationMinutes,
      'order': order,
      'sessionNumber': sessionNumber,
    };

    if (includeRecordedExtras) {
      map['videoUrl'] = videoUrl;
      map['videoThumbnailUrl'] = videoThumbnailUrl;

    }
    if (includeOnlineExtras) {
      map['materialsUrl'] = materialsUrl;
    }

    return map;
  }
  factory SyllabusSession.fromMap(Map m) {
    return SyllabusSession(
      id: (m['id'] ?? '').toString(),
      title: (m['title'] ?? '').toString(),
      skillType: SkillTypeX.fromString((m['skillType'] ?? '').toString()),
      objective: (m['objective'] ?? '').toString(),
      content: (m['content'] ?? '').toString(),
      homework: (m['homework'] ?? '').toString(),
      durationMinutes: (m['durationMinutes'] is num)
          ? (m['durationMinutes'] as num).toInt()
          : (int.tryParse('${m['durationMinutes']}') ?? 45),
      order: (m['order'] is num)
          ? (m['order'] as num).toInt()
          : (int.tryParse('${m['order']}') ?? 0),

      // ✅ NEW: if missing, default 0, then _ensureSessionNumbers() will fix it
      sessionNumber: (m['sessionNumber'] is num)
          ? (m['sessionNumber'] as num).toInt()
          : (int.tryParse('${m['sessionNumber']}') ?? 0),
      videoUrl: (m['videoUrl'] ?? '').toString(),
      videoThumbnailUrl: (m['videoThumbnailUrl'] ?? '').toString(),
      materialsUrl: (m['materialsUrl'] ?? '').toString(),
    );
  }
}

