import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';

import '../shared/app_theme.dart';
import '../shared/human_error.dart';
import '../shared/teacher_web_layout.dart';
import '../shared/watermark_background.dart';
import 'teacher_syllabus_details_screen.dart';

class TeacherSyllabiScreen extends StatefulWidget {
  const TeacherSyllabiScreen({super.key});

  @override
  State<TeacherSyllabiScreen> createState() => _TeacherSyllabiScreenState();
}

class _TeacherSyllabiScreenState extends State<TeacherSyllabiScreen> {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  final TextEditingController _searchController = TextEditingController();

  bool _loading = true;
  String? _error;

  List<_SyllabusLite> _items = const [];
  String _query = '';
  String _variantFilter = 'all';
  bool _searchMode = false;
  bool _deepSearch = false;

  @override
  void initState() {
    super.initState();
    appThemeController.addListener(_onThemeChanged);
    _load();
  }

  @override
  void dispose() {
    appThemeController.removeListener(_onThemeChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onThemeChanged() {
    if (!mounted) return;
    setState(() {});
  }

  AppPalette get p => appThemeController.palette;

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _items = const [];
    });

    try {
      final snap = await _db.child('syllabi').get();
      final v = snap.value;

      if (v is! Map) {
        setState(() {
          _loading = false;
          _items = const [];
        });
        return;
      }

      final raw = Map<dynamic, dynamic>.from(v);
      final out = <_SyllabusLite>[];

      raw.forEach((key, value) {
        final courseMap = _asStringKeyMap(value);
        if (courseMap == null) return;

        final fallbackMeta = _firstVariantMeta(courseMap);

        final courseId = _readString(courseMap['courseId']).isNotEmpty
            ? _readString(courseMap['courseId'])
            : key.toString();

        final title = _firstNonEmpty([
          _readString(courseMap['title']),
          _readString(fallbackMeta?['title']),
          'Course',
        ]);

        final code = _firstNonEmpty([
          _readString(courseMap['courseCode']),
          _readString(fallbackMeta?['courseCode']),
          '',
        ]);

        final duration = _firstNonEmpty([
          _readString(courseMap['duration']),
          _readString(fallbackMeta?['duration']),
          '',
        ]);

        final updatedAt = _maxInt([
          _toInt(courseMap['updatedAt']),
          _toInt(fallbackMeta?['updatedAt']),
        ]);

        final variants = _extractAvailableVariants(courseMap);
        final searchIndex = _buildSearchIndex(
          courseMap: courseMap,
          courseId: courseId,
          title: title,
          code: code,
          duration: duration,
          variants: variants,
        );

        out.add(
          _SyllabusLite(
            courseId: courseId,
            title: title,
            code: code,
            duration: duration,
            updatedAt: updatedAt,
            variants: variants,
            normalSearchText: searchIndex.normalText,
            deepEntries: searchIndex.deepEntries,
          ),
        );
      });

      out.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

      if (!mounted) return;
      setState(() {
        _loading = false;
        _items = out;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = toHumanError(e);
      });
    }
  }

  Map<String, dynamic>? _asStringKeyMap(dynamic value) {
    if (value is! Map) return null;

    final out = <String, dynamic>{};
    value.forEach((k, v) {
      out[k.toString()] = v;
    });
    return out;
  }

  Map<String, dynamic>? _firstVariantMeta(Map<String, dynamic> courseMap) {
    for (final key in const ['inclass', 'flexible', 'private', 'recorded']) {
      final variant = _asStringKeyMap(courseMap[key]);
      if (variant != null) return variant;
    }
    return null;
  }

  List<String> _extractAvailableVariants(Map<String, dynamic> courseMap) {
    final out = <String>[];

    for (final key in const ['inclass', 'flexible', 'private', 'recorded']) {
      final variant = _asStringKeyMap(courseMap[key]);
      if (variant == null) continue;

      final hasUnits =
          variant['units'] is List && (variant['units'] as List).isNotEmpty;
      final hasModules =
          variant['modules'] is List && (variant['modules'] as List).isNotEmpty;
      final hasMeta =
          _readString(variant['title']).isNotEmpty ||
          _readString(variant['courseCode']).isNotEmpty ||
          _readString(variant['duration']).isNotEmpty ||
          _toInt(variant['updatedAt']) > 0;

      if (hasUnits || hasModules || hasMeta) {
        out.add(key);
      }
    }

    return out;
  }

  _SearchIndex _buildSearchIndex({
    required Map<String, dynamic> courseMap,
    required String courseId,
    required String title,
    required String code,
    required String duration,
    required List<String> variants,
  }) {
    final normalParts = <String>[
      courseId,
      title,
      code,
      duration,
      ...variants.map(_variantLabel),
    ];

    for (final key in const ['inclass', 'flexible', 'private', 'recorded']) {
      final variant = _asStringKeyMap(courseMap[key]);
      if (variant == null) continue;
      normalParts.addAll([
        _readString(variant['title']),
        _readString(variant['courseCode']),
        _readString(variant['duration']),
      ]);
    }

    final deepEntries = <_DeepSearchEntry>[];
    for (final key in const ['inclass', 'flexible', 'private', 'recorded']) {
      deepEntries.addAll(_extractVariantDeepEntries(key, courseMap));
    }

    return _SearchIndex(
      normalText: _searchText(normalParts),
      deepEntries: deepEntries,
    );
  }

  List<_DeepSearchEntry> _extractVariantDeepEntries(
    String variantKey,
    Map<String, dynamic> courseMap,
  ) {
    final variant = _asStringKeyMap(courseMap[variantKey]);
    if (variant == null) return const <_DeepSearchEntry>[];

    final variantLabel = _variantLabel(variantKey);
    final out = <_DeepSearchEntry>[];

    final modules = _asListOfMaps(variant['modules']);
    if (modules.isNotEmpty) {
      for (int mi = 0; mi < modules.length; mi++) {
        final module = modules[mi];
        final moduleLabel = _firstNonEmpty([
          _readString(module['otherTitle']),
          _readString(module['title']),
          'Module ${mi + 1}',
        ]);
        final units = _asListOfMaps(module['units']);
        _appendDeepEntriesFromUnits(
          out: out,
          variantLabel: variantLabel,
          moduleLabel: moduleLabel,
          unitMaps: units,
          primarySessionKey: 'lessons',
        );
      }
    }

    _appendDeepEntriesFromUnits(
      out: out,
      variantLabel: variantLabel,
      moduleLabel: '',
      unitMaps: _asListOfMaps(variant['units']),
      primarySessionKey: variantKey == 'recorded' ? 'lessons' : 'sessions',
    );

    return out;
  }

  void _appendDeepEntriesFromUnits({
    required List<_DeepSearchEntry> out,
    required String variantLabel,
    required String moduleLabel,
    required List<Map<String, dynamic>> unitMaps,
    required String primarySessionKey,
  }) {
    for (int ui = 0; ui < unitMaps.length; ui++) {
      final unit = unitMaps[ui];
      final unitLabel = _firstNonEmpty([
        _readString(unit['otherTitle']),
        _readString(unit['title']),
        'Unit ${ui + 1}',
      ]);

      final unitContext = _searchText([variantLabel, moduleLabel, unitLabel]);

      out.add(
        _DeepSearchEntry(
          haystack: _searchText([
            variantLabel,
            moduleLabel,
            unitLabel,
            _readString(unit['id']),
            _readString(unit['description']),
          ]),
          context: unitContext,
        ),
      );

      List<Map<String, dynamic>> sessions = _asListOfMaps(
        unit[primarySessionKey],
      );
      if (sessions.isEmpty) {
        sessions = _asListOfMaps(
          unit[primarySessionKey == 'lessons' ? 'sessions' : 'lessons'],
        );
      }

      for (int si = 0; si < sessions.length; si++) {
        final session = sessions[si];
        final sessionLabel = _firstNonEmpty([
          _readString(session['title']),
          _readString(session['id']),
          'Session ${si + 1}',
        ]);

        final sessionContext = _searchText([
          variantLabel,
          moduleLabel,
          unitLabel,
          sessionLabel,
        ]);

        out.add(
          _DeepSearchEntry(
            haystack: _searchText([
              variantLabel,
              moduleLabel,
              unitLabel,
              _readString(unit['id']),
              _readString(unit['description']),
              _readString(session['id']),
              _readString(session['title']),
              _readString(session['skillType']),
              _readString(session['objective']),
              _readString(session['content']),
              _readString(session['homework']),
            ]),
            context: sessionContext,
          ),
        );
      }
    }
  }

  static List<Map<String, dynamic>> _asListOfMaps(dynamic node) {
    final out = <Map<String, dynamic>>[];

    if (node is List) {
      for (final x in node) {
        if (x is Map) out.add(Map<String, dynamic>.from(x));
      }
      return out;
    }

    if (node is Map) {
      final mm = Map<dynamic, dynamic>.from(node);
      for (final entry in mm.entries) {
        final value = entry.value;
        if (value is Map) out.add(Map<String, dynamic>.from(value));
      }
      return out;
    }

    return out;
  }

  static String _searchText(List<String> parts) => parts
      .map((e) => e.trim().toLowerCase())
      .where((e) => e.isNotEmpty)
      .join(' ');

  List<_SyllabusLite> _filteredItems() {
    final q = _query.trim().toLowerCase();

    return _items.where((item) {
      final matchesVariant =
          _variantFilter == 'all' || item.variants.contains(_variantFilter);
      if (!matchesVariant) return false;
      if (q.isEmpty) return true;

      final normalMatch = item.normalSearchText.contains(q);
      if (!_deepSearch) return normalMatch;
      if (normalMatch) return true;

      for (final entry in item.deepEntries) {
        if (entry.haystack.contains(q)) return true;
      }
      return false;
    }).toList();
  }

  String? _deepMatchContext(_SyllabusLite item) {
    final q = _query.trim().toLowerCase();
    if (!_deepSearch || q.isEmpty) return null;

    final out = <String>[];
    for (final entry in item.deepEntries) {
      if (!entry.haystack.contains(q)) continue;
      if (out.contains(entry.context)) continue;
      out.add(entry.context);
      if (out.length >= 2) break;
    }

    if (out.isEmpty) return null;
    return out.join('  •  ');
  }

  static String _readString(dynamic v) => (v ?? '').toString().trim();

  static String _firstNonEmpty(List<String> values) {
    for (final v in values) {
      if (v.trim().isNotEmpty) return v.trim();
    }
    return '';
  }

  static int _toInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  static int _maxInt(List<int> values) {
    if (values.isEmpty) return 0;
    var max = values.first;
    for (final v in values) {
      if (v > max) max = v;
    }
    return max;
  }

  String _fmtDate(int ms) {
    if (ms <= 0) return '';
    try {
      final dt = DateTime.fromMillisecondsSinceEpoch(ms);
      final y = dt.year.toString().padLeft(4, '0');
      final m = dt.month.toString().padLeft(2, '0');
      final d = dt.day.toString().padLeft(2, '0');
      return '$y-$m-$d';
    } catch (_) {
      return '';
    }
  }

  String _variantLabel(String key) {
    switch (key) {
      case 'inclass':
        return 'In-Class';
      case 'flexible':
        return 'Flexible';
      case 'private':
        return 'Private';
      case 'recorded':
        return 'Recorded';
      default:
        return key;
    }
  }

  @override
  Widget build(BuildContext context) {
    final filteredItems = _filteredItems();
    final hasActiveQuery = _query.trim().isNotEmpty;
    final hasActiveFilter = _variantFilter != 'all';


    return Scaffold(
      backgroundColor: p.appBg,
      appBar: AppBar(
        backgroundColor: p.cardBg,
        elevation: 0,
        surfaceTintColor: p.cardBg,
        centerTitle: false,
        iconTheme: IconThemeData(color: p.primary),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Syllabi',
              style: TextStyle(
                color: p.primary,
                fontWeight: FontWeight.w900,
                fontSize: 18,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              'Browse course outlines and available variants',
              style: TextStyle(
                color: p.text.withValues(alpha: 0.65),
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
          ],
        ),
        actions: [
          const SizedBox.shrink(),
          IconButton(
            tooltip: 'Refresh',
            icon: Icon(Icons.refresh_rounded, color: p.accent),
            onPressed: _load,
          ),
        ],
      ),
      body: teacherWebBodyFrame(
        context: context,
        maxWidth: 1320,
        child: WatermarkBackground(
          child: SafeArea(
            child: _loading
                ? Center(child: CircularProgressIndicator(color: p.accent))
                : _error != null
                ? _ErrorBox(
                    palette: p,
                    message: 'Failed to load syllabi.\n$_error',
                    onRetry: _load,
                  )
                : _items.isEmpty
                ? _InfoBox(
                    palette: p,
                    title: 'No syllabi',
                    message: 'No syllabi are available right now.',
                    icon: Icons.info_rounded,
                  )
                : ListView(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
                    children: [
                      _SyllabiSearchBar(
                        palette: p,
                        controller: _searchController,
                        deepSearch: _deepSearch,
                        searchMode: _searchMode,
                        variantFilter: _variantFilter,
                        shownCount: filteredItems.length,
                        totalCount: _items.length,
                        onQueryChanged: (value) {
                          setState(() {
                            _query = value;
                          });
                        },
                        onClearQuery: () {
                          _searchController.clear();
                          setState(() {
                            _query = '';
                          });
                        },
                        onToggleDeep: () {
                          setState(() {
                            _deepSearch = !_deepSearch;
                          });
                        },
                        onToggleSearchMode: () {
                          setState(() {
                            _searchMode = !_searchMode;
                          });
                          if (_searchMode) FocusScope.of(context).unfocus();
                        },
                        onVariantChanged: (value) {
                          if (value == null) return;
                          setState(() {
                            _variantFilter = value;
                          });
                        },
                      ),
                      const SizedBox(height: 12),
                      if (filteredItems.isEmpty)
                        _InfoBox(
                          palette: p,
                          title: 'No matches',
                          message: hasActiveQuery || hasActiveFilter
                              ? 'No syllabi match your current search/filter.'
                              : 'No syllabi are available right now.',
                          icon: Icons.search_off_rounded,
                        )
                      else
                        ...filteredItems.map((it) {
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: _SyllabusTile(
                              palette: p,
                              title: it.title,
                              code: it.code,
                              duration: it.duration,
                              updatedLabel: _fmtDate(it.updatedAt),
                              variants: it.variants.map(_variantLabel).toList(),
                              matchContext: _deepMatchContext(it),
                              matchQuery: _query,
                              onTap: () {
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        TeacherSyllabusDetailsScreen(
                                          courseId: it.courseId,
                                        ),
                                  ),
                                );
                              },
                            ),
                          );
                        }),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

class _SyllabusLite {
  const _SyllabusLite({
    required this.courseId,
    required this.title,
    required this.code,
    required this.duration,
    required this.updatedAt,
    required this.variants,
    required this.normalSearchText,
    required this.deepEntries,
  });

  final String courseId;
  final String title;
  final String code;
  final String duration;
  final int updatedAt;
  final List<String> variants;
  final String normalSearchText;
  final List<_DeepSearchEntry> deepEntries;
}

/* ================== UI ================== */

class _SyllabiSearchBar extends StatelessWidget {
  const _SyllabiSearchBar({
    required this.palette,
    required this.controller,
    required this.deepSearch,
    required this.searchMode,
    required this.variantFilter,
    required this.shownCount,
    required this.totalCount,
    required this.onQueryChanged,
    required this.onClearQuery,
    required this.onToggleDeep,
    required this.onToggleSearchMode,
    required this.onVariantChanged,
  });

  final AppPalette palette;
  final TextEditingController controller;
  final bool deepSearch;
  final bool searchMode;
  final String variantFilter;
  final int shownCount;
  final int totalCount;
  final ValueChanged<String> onQueryChanged;
  final VoidCallback onClearQuery;
  final VoidCallback onToggleDeep;
  final VoidCallback onToggleSearchMode;
  final ValueChanged<String?> onVariantChanged;

  @override
  Widget build(BuildContext context) {
    final hasText = controller.text.trim().isNotEmpty;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: palette.border.withValues(alpha: 0.9)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  textInputAction: TextInputAction.search,
                  onChanged: onQueryChanged,
                  decoration: InputDecoration(
                    hintText: deepSearch
                        ? 'Deep search topics, grammar, objective, content...'
                        : 'Search course title, code, variant...',
                    prefixIcon: Icon(
                      Icons.search_rounded,
                      color: palette.primary,
                    ),
                    suffixIcon: hasText
                        ? IconButton(
                            tooltip: 'Clear',
                            onPressed: onClearQuery,
                            icon: const Icon(Icons.clear_rounded),
                          )
                        : null,
                    isDense: true,
                    filled: true,
                    fillColor: palette.soft.withValues(alpha: 0.55),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 12,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(
                        color: palette.border.withValues(alpha: 0.85),
                      ),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(
                        color: palette.border.withValues(alpha: 0.85),
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(
                        color: palette.primary,
                        width: 1.2,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              InkWell(
                onTap: onToggleDeep,
                borderRadius: BorderRadius.circular(999),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 9,
                  ),
                  decoration: BoxDecoration(
                    color: deepSearch
                        ? palette.primary.withValues(alpha: 0.1)
                        : palette.soft,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: deepSearch
                          ? palette.primary.withValues(alpha: 0.65)
                          : palette.border.withValues(alpha: 0.85),
                    ),
                  ),
                  child: Text(
                    'Deep',
                    style: TextStyle(
                      color: deepSearch ? palette.primary : palette.text,
                      fontWeight: FontWeight.w900,
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
              IconButton(
                tooltip: searchMode ? 'Show filter' : 'Search focus mode',
                onPressed: onToggleSearchMode,
                icon: Icon(
                  searchMode ? Icons.close_rounded : Icons.search_rounded,
                  color: palette.accent,
                ),
              ),
            ],
          ),
          if (!searchMode) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Container(
                    height: 42,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: palette.soft.withValues(alpha: 0.45),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: palette.border.withValues(alpha: 0.9),
                      ),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: variantFilter,
                        isExpanded: true,
                        borderRadius: BorderRadius.circular(12),
                        dropdownColor: palette.cardBg,
                        style: TextStyle(
                          color: palette.text,
                          fontWeight: FontWeight.w800,
                          fontSize: 13,
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'all',
                            child: Text('All variants'),
                          ),
                          DropdownMenuItem(
                            value: 'inclass',
                            child: Text('In-Class'),
                          ),
                          DropdownMenuItem(
                            value: 'flexible',
                            child: Text('Flexible'),
                          ),
                          DropdownMenuItem(
                            value: 'private',
                            child: Text('Private'),
                          ),
                          DropdownMenuItem(
                            value: 'recorded',
                            child: Text('Recorded'),
                          ),
                        ],
                        onChanged: onVariantChanged,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 9,
                  ),
                  decoration: BoxDecoration(
                    color: palette.soft.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: palette.border.withValues(alpha: 0.82),
                    ),
                  ),
                  child: Text(
                    '$shownCount / $totalCount',
                    style: TextStyle(
                      color: palette.primary,
                      fontWeight: FontWeight.w900,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _SyllabusTile extends StatelessWidget {
  const _SyllabusTile({
    required this.palette,
    required this.title,
    required this.code,
    required this.duration,
    required this.updatedLabel,
    required this.variants,
    this.matchContext,
    this.matchQuery = '',
    required this.onTap,
  });

  final AppPalette palette;
  final String title;
  final String code;
  final String duration;
  final String updatedLabel;
  final List<String> variants;
  final String? matchContext;
  final String matchQuery;
  final VoidCallback onTap;

  List<TextSpan> _buildHighlightedSpans({
    required String text,
    required String query,
    required TextStyle normalStyle,
    required TextStyle highlightStyle,
  }) {
    final terms =
        query
            .trim()
            .toLowerCase()
            .split(RegExp(r'\s+'))
            .where((e) => e.isNotEmpty)
            .toSet()
            .toList()
          ..sort((a, b) => b.length.compareTo(a.length));

    if (terms.isEmpty) return [TextSpan(text: text, style: normalStyle)];

    final lower = text.toLowerCase();
    final marks = List<bool>.filled(text.length, false);

    for (final term in terms) {
      int start = 0;
      while (start < lower.length) {
        final idx = lower.indexOf(term, start);
        if (idx < 0) break;
        final end = idx + term.length;
        for (int i = idx; i < end && i < marks.length; i++) {
          marks[i] = true;
        }
        start = idx + 1;
      }
    }

    final spans = <TextSpan>[];
    int i = 0;
    while (i < text.length) {
      final highlighted = marks[i];
      int j = i + 1;
      while (j < text.length && marks[j] == highlighted) {
        j++;
      }
      spans.add(
        TextSpan(
          text: text.substring(i, j),
          style: highlighted ? highlightStyle : normalStyle,
        ),
      );
      i = j;
    }

    return spans;
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(22),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: palette.cardBg,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: palette.border.withValues(alpha: 0.88)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.03),
              blurRadius: 10,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: palette.soft,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: palette.border.withValues(alpha: 0.85),
                ),
              ),
              child: Icon(Icons.menu_book_rounded, color: palette.primary),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      color: palette.primary,
                      fontSize: 15,
                      height: 1.2,
                    ),
                  ),
                  if ((matchContext ?? '').trim().isNotEmpty) ...[
                    const SizedBox(height: 7),
                    RichText(
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      text: TextSpan(
                        children: _buildHighlightedSpans(
                          text: matchContext!,
                          query: matchQuery,
                          normalStyle: TextStyle(
                            fontSize: 12,
                            height: 1.3,
                            fontWeight: FontWeight.w700,
                            color: palette.text.withValues(alpha: 0.74),
                          ),
                          highlightStyle: TextStyle(
                            fontSize: 12,
                            height: 1.3,
                            fontWeight: FontWeight.w900,
                            color: palette.primary,
                            backgroundColor: palette.soft.withValues(
                              alpha: 0.8,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (code.trim().isNotEmpty)
                        _Pill(
                          palette: palette,
                          icon: Icons.qr_code_rounded,
                          text: code,
                        ),
                      if (duration.trim().isNotEmpty)
                        _Pill(
                          palette: palette,
                          icon: Icons.timer_rounded,
                          text: duration,
                        ),
                      if (updatedLabel.trim().isNotEmpty)
                        _Pill(
                          palette: palette,
                          icon: Icons.update_rounded,
                          text: updatedLabel,
                        ),
                    ],
                  ),
                  if (variants.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: variants
                          .map(
                            (v) => _Pill(
                              palette: palette,
                              icon: Icons.layers_rounded,
                              text: v,
                            ),
                          )
                          .toList(),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 10),
            Icon(
              Icons.chevron_right_rounded,
              color: palette.text.withValues(alpha: 0.45),
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchIndex {
  const _SearchIndex({required this.normalText, required this.deepEntries});

  final String normalText;
  final List<_DeepSearchEntry> deepEntries;
}

class _DeepSearchEntry {
  const _DeepSearchEntry({required this.haystack, required this.context});

  final String haystack;
  final String context;
}

class _Pill extends StatelessWidget {
  const _Pill({required this.palette, required this.icon, required this.text});

  final AppPalette palette;
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final maxWidth = MediaQuery.of(context).size.width * 0.55;

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: palette.soft.withValues(alpha: 0.8),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: palette.border.withValues(alpha: 0.75)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: palette.primary),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  color: palette.primary,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoBox extends StatelessWidget {
  const _InfoBox({
    required this.palette,
    required this.title,
    required this.message,
    required this.icon,
  });

  final AppPalette palette;
  final String title;
  final String message;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: palette.cardBg,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: palette.border.withValues(alpha: 0.86)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 58,
              height: 58,
              decoration: BoxDecoration(
                color: palette.soft,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: palette.primary, size: 30),
            ),
            const SizedBox(height: 12),
            Text(
              title,
              style: TextStyle(
                fontWeight: FontWeight.w900,
                color: palette.primary,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: palette.text.withValues(alpha: 0.72),
                height: 1.35,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({
    required this.palette,
    required this.message,
    required this.onRetry,
  });

  final AppPalette palette;
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: palette.cardBg,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: palette.border.withValues(alpha: 0.86)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.error_outline_rounded,
              color: Color(0xFFD97706),
              size: 34,
            ),
            const SizedBox(height: 10),
            Text(
              'Error',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                color: palette.primary,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: palette.text.withValues(alpha: 0.72),
                height: 1.35,
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: palette.accent,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text(
                  'Retry',
                  style: TextStyle(fontWeight: FontWeight.w900),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
