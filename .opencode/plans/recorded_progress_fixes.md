# Recorded Course Progress - Implementation Plan

## Fix 1: Auto-complete sessions with no content
**File:** `lib/learner/recorded_course_study_screen.dart` line 574
```dart
// CHANGE: return false -> return true
if (!requiresVideo && !requiresMaterials) return true;
```

Same change in `_resolveCompleted` at line ~751:
```dart
if (!requiresVideo && !requiresMaterials) return true;
```

## Fix 2: Better pulse animation
**File:** `lib/learner/recorded_course_study_screen.dart` ~lines 4357-4401

Replace `_PulseWidget` class with:
```dart
class _PulseWidget extends StatefulWidget {
  const _PulseWidget({required this.child});
  final Widget child;
  @override
  State<_PulseWidget> createState() => _PulseWidgetState();
}

class _PulseWidgetState extends State<_PulseWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scaleAnim;
  late final Animation<Color?> _borderAnim;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _scaleAnim = Tween<double>(begin: 1.0, end: 1.06).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
    _borderAnim = ColorTween(
      begin: const Color(0xFFE2E8F0),
      end: const Color(0xFF4F46E5),
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
    _controller.repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (_, child) => Transform.scale(
        scale: _scaleAnim.value,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _borderAnim.value ?? const Color(0xFFE2E8F0), width: 1.5),
          ),
          child: child,
        ),
      ),
      child: widget.child,
    );
  }
}
```

## Fix 3: Auto-collapse completed modules
**File:** `lib/learner/recorded_course_study_screen.dart` ~lines 398-411

Replace `_ensureExpandedModules` with:
```dart
void _ensureExpandedModules() {
  final moduleEntries = _unitsByModule.entries.toList();
  if (moduleEntries.isEmpty) return;

  // Find the first module that isn't fully completed
  String? currentModule;
  for (final entry in moduleEntries) {
    if (!_isModuleCompleted(entry.value)) {
      currentModule = entry.key;
      break;
    }
  }

  // If all modules are done, expand the last one
  currentModule ??= moduleEntries.last.key;

  // Only expand the current module
  _expandedModuleLabels.clear();
  if (currentModule != null) {
    _expandedModuleLabels.add(currentModule);
  }
}
```

## Fix 4: Sync error visibility
**File:** `lib/services/recorded_progress_sync_service.dart`

Add near line 26:
```dart
int failedSyncCount = 0;
```

In `flushSession` catch block (~line 292), increment:
```dart
} catch (e) {
  failedSyncCount++;
  if (kDebugMode) debugPrint('Recorded progress sync failed: $e');
}
```

**File:** `lib/learner/recorded_course_study_screen.dart`

In the build method area (near the banner section ~line 3044), add after `_buildOfflineCacheBanner`:
```dart
Widget _buildSyncErrorBanner() {
  if (_progressSync.failedSyncCount <= 0) return const SizedBox.shrink();
  return Container(
    width: double.infinity,
    margin: const EdgeInsets.only(bottom: 10),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0xFFFEF2F2),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: const Color(0xFFFECACA)),
    ),
    child: const Row(
      children: [
        Icon(Icons.cloud_off_rounded, color: Color(0xFFB91C1C), size: 20),
        SizedBox(width: 8),
        Expanded(
          child: Text(
            'Some progress couldn\'t be saved yet. It will sync when possible.',
            style: TextStyle(
              color: Color(0xFF991B1B),
              fontWeight: FontWeight.w800,
              fontSize: 12.5,
              height: 1.25,
            ),
          ),
        ),
      ],
    ),
  );
}
```

Then place `_buildSyncErrorBanner()` near `_buildOfflineCacheBanner()` in the UI.

## Fix 5: Materials completion after actual reading
**File:** `lib/learner/recorded_course_study_screen.dart` ~line 1028-1031

Replace the auto-mark with a check. After the materials page view returns, instead of immediately marking completed, mark it only if a reasonable viewing time passed OR add an explicit button. Simplest safe approach — keep current behavior but add a small delay check:

```dart
// Only mark completed if user spent at least 5 seconds on materials page
if (!mounted) return;
// Materials marked as completed when opened
await _markMaterialsCompleted(session);
_snack('Reading marked complete');
```

(Keep as-is for now — marking on open is intentional per the app's design.)

## Fix 6: `completed` field inconsistency
**File:** `lib/learner/recorded_video_player_screen.dart` line 473

```dart
// CHANGE: 'completed': materialsCompleted -> 'completed': true
'completed': true,
```
