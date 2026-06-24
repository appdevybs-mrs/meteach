# Fix Learner Profile Progress (00% bug) + Teacher Profile Per-Course Cards

## Problem

1. **Learner home page course cards show 0% progress** — `_loadCourseMeta()` in `learner_home.dart` only tries the exact `variantKey` from `course['variantKey']` when loading the syllabus at `syllabi/{courseId}/{variantKey}`. If the stored variant doesn't match the syllabus path (e.g., course says `"online"` but syllabus lives under `"flexible"`), `totalLessons = 0` → progress = 0%.

2. **Teacher learner profile screen** (`teacher_learner_profile_screen.dart`) has the same single-variant-key issue in `_loadSessionIdByNumber()`, causing `_statLessonsCovered` and `_statAttendancePct` to be 0.

3. **Teacher profile shows only aggregate stats** — no per-course progress cards for the teacher to see each course's progress ring.

4. **Online attendance counting bug** — `_loadSmallStats()` doesn't guard with `rec.containsKey('present')`, inflating the attendance denominator.

The **learner course detail screen** (`learner_course_detail_screen.dart:1619-1688`) already solves this with a multi-candidate search — we replicate that pattern.

---

## Step 1: Fix `learner_home.dart` — `_loadCourseMeta()` variant resolution

**File:** `lib/learner/learner_home.dart`  
**Lines:** 1982–2040

**Change:** Replace the simple single-variant-key lookup with the multi-candidate search pattern from `learner_course_detail_screen.dart:1619-1688`.

**New logic (replace the syllabus loading block):**
```dart
int totalLessons = 0;
if (courseId.isNotEmpty) {
  try {
    final rootSyllabusRef = _db.child('syllabi/$courseId');

    final List<String> variantCandidates = [];
    void addCandidate(String v) {
      final x = v.trim().toLowerCase();
      if (x.isEmpty) return;
      if (!variantCandidates.contains(x)) variantCandidates.add(x);
    }

    addCandidate(variantKey);
    final classVariant = (cls['variantKey'] ?? cls['variant'] ?? '')
        .toString().trim().toLowerCase();
    addCandidate(classVariant);
    final deliveryKey = resolveCourseDeliveryKey(course);
    addCandidate(deliveryKey);

    final norm = deliveryKey;
    if (norm == 'private') {
      addCandidate('private');
      addCandidate('online');
      addCandidate('inclass');
      addCandidate('in_class');
    } else if (norm == 'flexible') {
      addCandidate('flexible');
      addCandidate('online');
    } else if (norm == 'inclass') {
      addCandidate('inclass');
      addCandidate('in_class');
    } else if (norm == 'recorded') {
      addCandidate('recorded');
    }

    DataSnapshot? sSnap;
    for (final key in variantCandidates) {
      final testSnap = await rootSyllabusRef
          .child(key)
          .get()
          .timeout(const Duration(seconds: 10));
      if (testSnap.exists &&
          testSnap.value != null &&
          testSnap.value is Map) {
        sSnap = testSnap;
        break;
      }
    }

    sSnap ??= await rootSyllabusRef.get().timeout(
      const Duration(seconds: 10),
    );

    if (sSnap != null && sSnap.exists && sSnap.value is Map) {
      // keep existing syllabus parsing code unchanged
      final s = Map<String, dynamic>.from(sSnap.value as Map);
      ...
    }
  } catch (_) {}
}
```

`resolveCourseDeliveryKey` is already imported via `lib/shared/course_join_rules.dart` (line 37).

---

## Step 2: Fix `teacher_learner_profile_screen.dart` — `_loadSessionIdByNumber()` variant resolution

**File:** `lib/teacher/teacher_learner_profile_screen.dart`  
**Lines:** 80–146

**Change:** Apply the same multi-candidate search in `_loadSessionIdByNumber()`.

**New logic:**
```dart
Future<Map<int, String>> _loadSessionIdByNumber({
  required String courseId,
  required String variantKey,
}) async {
  final out = <int, String>{};
  if (courseId.trim().isEmpty) return out;

  try {
    final rootSyllabusRef = _db.child('syllabi/$courseId');

    final List<String> candidates = [];
    void addCandidate(String v) {
      final x = v.trim().toLowerCase();
      if (x.isEmpty) return;
      if (!candidates.contains(x)) candidates.add(x);
    }

    addCandidate(variantKey);
    // Add normalized forms
    final nk = normalizeVariantKey(variantKey, fallback: '');
    if (nk.isNotEmpty) addCandidate(nk);

    final norm = nk.isNotEmpty ? nk : variantKey;
    if (norm == 'private') {
      addCandidate('private');
      addCandidate('online');
      addCandidate('inclass');
      addCandidate('in_class');
    } else if (norm == 'flexible') {
      addCandidate('flexible');
      addCandidate('online');
    } else if (norm == 'inclass' || norm.isEmpty) {
      addCandidate('inclass');
      addCandidate('in_class');
    } else if (norm == 'recorded') {
      addCandidate('recorded');
    }

    DataSnapshot? sSnap;
    for (final key in candidates) {
      final testSnap = await rootSyllabusRef
          .child(key)
          .get()
          .timeout(const Duration(seconds: 10));
      if (testSnap.exists &&
          testSnap.value != null &&
          testSnap.value is Map) {
        sSnap = testSnap;
        break;
      }
    }

    sSnap ??= await rootSyllabusRef.get().timeout(
      const Duration(seconds: 10),
    );

    if (sSnap == null || !sSnap.exists) return out;

    final data = Map<String, dynamic>.from(sSnap.value as Map);
    // keep existing parsing code unchanged
    ...
  } catch (_) {}
  return out;
}
```

**Add import** at top of file:
```dart
import '../shared/study_variant.dart';
```

---

## Step 3: Fix online attendance counting in `_loadSmallStats()`

**File:** `lib/teacher/teacher_learner_profile_screen.dart`  
**Lines:** 340–358

**Change:** The online attendance loop at line 349-355 currently counts every record as `totalAttendance += 1` without checking if the record has a `present` key. Add the `containsKey` guard (same as learner_profile_screen.dart line 1136-1137).

**Current code (lines 349-355):**
```dart
for (final item in om.values) {
  if (item is! Map) continue;
  final rec = Map<String, dynamic>.from(item);

  totalAttendance += 1;
  final present = rec['present'] == true;
  if (present) totalPresent += 1;
}
```

**New code:**
```dart
for (final item in om.values) {
  if (item is! Map) continue;
  final rec = Map<String, dynamic>.from(item);

  final hasPresentFlag = rec.containsKey('present');
  if (!hasPresentFlag) continue;

  totalAttendance += 1;
  final present = rec['present'] == true;
  if (present) totalPresent += 1;
}
```

---

## Step 4: Add per-course progress cards to `TeacherLearnerProfileScreen`

**File:** `lib/teacher/teacher_learner_profile_screen.dart`

This is the largest change. The teacher profile currently shows only aggregate stats. We need to add a section below the summary card that shows each enrolled course as a progress card.

### 4a. Add new state variables

Add below existing stat variables (after line 49 `_statHomeworkPending`):

```dart
List<_TeacherCourseCardItem> _courseCards = [];
bool _loadingCourses = false;
```

### 4b. Create a data class `_TeacherCourseCardItem`

Add near the bottom of the file (before the `_ReportCardDiagramV3` class at line 1801):

```dart
class _TeacherCourseCardItem {
  final String courseKey;
  final String title;
  final String code;
  final String variantKey;
  final String classType;
  final int completed;
  final int total;
  final double progress;
  final Map<String, dynamic> course;

  _TeacherCourseCardItem({
    required this.courseKey,
    required this.title,
    required this.code,
    required this.variantKey,
    required this.classType,
    required this.completed,
    required this.total,
    required this.progress,
    required this.course,
  });
}
```

### 4c. Add `_loadCourseCards()` method

Add a new method that iterates `users/{learnerUid}/courses` and computes per-course progress (similar to `learner_home.dart`'s `_loadProgressItems` but for the teacher's target learner):

```dart
Future<void> _loadCourseCards() async {
  _courseCards = [];
  try {
    final snap = await _db
        .child('users/${widget.learnerUid}/courses')
        .get()
        .timeout(const Duration(seconds: 10));
    if (!snap.exists || snap.value is! Map) return;

    final raw = Map<dynamic, dynamic>.from(snap.value as Map);
    final items = <_TeacherCourseCardItem>[];

    for (final e in raw.entries) {
      final key = e.key.toString();
      if (e.value is! Map) continue;
      final course = Map<String, dynamic>.from(e.value as Map);

      final cls = (course['class'] is Map)
          ? Map<String, dynamic>.from(course['class'] as Map)
          : <String, dynamic>{};
      final courseId = (cls['course_id'] ?? course['id'] ?? '').toString().trim();
      final title = (course['title'] ?? course['course_title'] ?? 'Course').toString().trim();
      final code = (course['course_code'] ?? '').toString().trim();
      final variantKey = (course['variantKey'] ?? course['variant'] ?? '').toString().trim().toLowerCase();

      // Load syllabus with multi-candidate search
      int totalLessons = 0;
      if (courseId.isNotEmpty) {
        try {
          final rootRef = _db.child('syllabi/$courseId');
          final List<String> candidates = [];
          void addCandidate(String v) {
            final x = v.trim().toLowerCase();
            if (x.isEmpty || candidates.contains(x)) return;
            candidates.add(x);
          }
          addCandidate(variantKey);
          final cv = (cls['variantKey'] ?? cls['variant'] ?? '').toString().trim().toLowerCase();
          addCandidate(cv);
          String norm = variantKey;
          if (norm == 'private' || norm == 'live' || norm == 'vip') {
            addCandidate('private'); addCandidate('online'); addCandidate('inclass'); addCandidate('in_class');
          } else if (norm == 'flexible' || norm == 'online') {
            addCandidate('flexible'); addCandidate('online');
          } else if (norm == 'inclass' || norm == 'in_class' || norm == 'in-class' || norm == 'in class' || norm == 'class') {
            addCandidate('inclass'); addCandidate('in_class');
          } else if (norm == 'recorded' || norm == 'record') {
            addCandidate('recorded');
          }

          DataSnapshot? sSnap;
          for (final c in candidates) {
            final ts = await rootRef.child(c).get().timeout(const Duration(seconds: 10));
            if (ts.exists && ts.value != null && ts.value is Map) { sSnap = ts; break; }
          }
          sSnap ??= await rootRef.get().timeout(const Duration(seconds: 10));
          if (sSnap != null && sSnap.exists && sSnap.value is Map) {
            final s = Map<String, dynamic>.from(sSnap.value as Map);
            final modules = s['modules'];
            if (modules is List) {
              for (final m in modules) {
                if (m is! Map) continue;
                final units = (m as Map)['units'];
                if (units is! List) continue;
                for (final u in units) {
                  if (u is! Map) continue;
                  final lessons = (u as Map)['lessons'];
                  if (lessons is List) totalLessons += lessons.length;
                }
              }
            } else {
              final units = s['units'];
              if (units is List) {
                for (final u in units) {
                  if (u is! Map) continue;
                  final sessions = (u as Map)['sessions'];
                  if (sessions is List) totalLessons += sessions.length;
                }
              }
            }
          }
        } catch (_) {}
      }

      // Count covered sessions from attendance
      final covered = await _coveredSessionIdsFromCourse(
        learnerUid: widget.learnerUid,
        course: course,
      );

      final total = totalLessons > 0 ? totalLessons : 0;
      final completed = total > 0 ? covered.length.clamp(0, total) : covered.length;
      final progress = total > 0 ? (completed / total).clamp(0.0, 1.0) : 0.0;

      items.add(_TeacherCourseCardItem(
        courseKey: key,
        title: title,
        code: code,
        variantKey: variantKey,
        classType: variantKey, // could be refined
        completed: completed,
        total: total,
        progress: progress,
        course: course,
      ));
    }

    items.sort((a, b) => b.progress.compareTo(a.progress));
    _courseCards = items;
  } catch (_) {}
}
```

### 4d. Add `_buildCourseCardsSection()` widget method

Add a method that renders the course cards in a horizontal scroll or grid:

```dart
Widget _buildCourseCardsSection(AppPalette p) {
  if (_courseCards.isEmpty) return const SizedBox.shrink();

  return Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: p.cardBg,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: p.border.withValues(alpha: 0.8)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Courses (${_courseCards.length})',
          style: TextStyle(
            color: p.primary,
            fontWeight: FontWeight.w900,
            fontSize: 16,
          ),
        ),
        const SizedBox(height: 12),
        ..._courseCards.map((item) => _buildCourseCard(p, item)),
      ],
    ),
  );
}

Widget _buildCourseCard(AppPalette p, _TeacherCourseCardItem item) {
  final percentText = (item.progress * 100).round();
  final accent = p.primary; // use variant-specific color

  return Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: p.primary.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: p.border.withValues(alpha: 0.85)),
      ),
      child: Row(
        children: [
          // Progress ring
          SizedBox(
            width: 60,
            height: 60,
            child: Stack(
              alignment: Alignment.center,
              children: [
                CircularProgressIndicator(
                  value: item.progress,
                  strokeWidth: 6,
                  backgroundColor: accent.withValues(alpha: 0.12),
                  valueColor: AlwaysStoppedAnimation(accent),
                ),
                Text(
                  '$percentText%',
                  style: TextStyle(
                    color: p.primary,
                    fontWeight: FontWeight.w900,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  style: TextStyle(
                    color: p.primary,
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                  ),
                ),
                if (item.code.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    item.code,
                    style: TextStyle(
                      color: p.text.withValues(alpha: 0.6),
                      fontWeight: FontWeight.w700,
                      fontSize: 11,
                    ),
                  ),
                ],
                const SizedBox(height: 4),
                Text(
                  '${item.completed} / ${item.total} lessons',
                  style: TextStyle(
                    color: p.text.withValues(alpha: 0.7),
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              item.classType.toUpperCase(),
              style: TextStyle(
                color: accent,
                fontWeight: FontWeight.w900,
                fontSize: 9,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
```

### 4e. Integrate into the build method

In `build()` (line 1742), after the summary card (line 1792), add the course cards section:

```dart
// After _buildSummaryCard(p) at line 1792:
const SizedBox(height: 14),
_buildCourseCardsSection(p),
```

And call `_loadCourseCards()` in `_load()` after `_loadSmallStats()` (line 414):

```dart
await _loadSmallStats();
await _loadCourseCards(); // add this line
```

---

## Step 5: Add import for `study_variant.dart`

**File:** `lib/teacher/teacher_learner_profile_screen.dart`

Add at the top with other imports (after line 13):

```dart
import '../shared/study_variant.dart';
```

---

## Summary of files changed

| File | Changes |
|------|---------|
| `lib/learner/learner_home.dart` | Step 1: multi-candidate variant search in `_loadCourseMeta()` |
| `lib/teacher/teacher_learner_profile_screen.dart` | Step 2: multi-candidate variant search in `_loadSessionIdByNumber()` + import |
| `lib/teacher/teacher_learner_profile_screen.dart` | Step 3: fix online attendance counting guard |
| `lib/teacher/teacher_learner_profile_screen.dart` | Step 4: add `_TeacherCourseCardItem` class, `_loadCourseCards()`, `_buildCourseCardsSection()`, `_buildCourseCard()` widgets, integrate into `_load()` and `build()` |
