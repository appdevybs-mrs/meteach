# Mail Thread Phase 1 Fixes

## Overview

Fixing 6 items identified in audit: 1 critical bug + 5 high-priority performance/UI issues across 4 mail thread screen files.

---

## File Locations

| File | Path | Lines |
|------|------|-------|
| Teacher | `/lib/teacher/teacher_mail_thread_screen.dart` | ~6109 |
| Learner | `/lib/learner/learner_mail_thread_screen.dart` | ~3776 |
| Admin Topic | `/lib/admin/mail_topic_thread_screen.dart` | ~3188 |
| Admin Teacher | `/lib/admin/admin_teacher_mail_thread_screen.dart` | ~2926 |

---

## Fix 1 (CRITICAL): `_send()` ignores `_recUploading` in admin screens

### The Bug
In `admin/mail_topic_thread_screen.dart` line 2231 and `admin/admin_teacher_mail_thread_screen.dart` line 1175:
```dart
if (_sending || _fileUploading) return;
```
Both screens check `_sending` and `_fileUploading` but **NOT** `_recUploading`. When `_recStopAndSend()` calls `_send()` while an audio recording is uploading, the send proceeds without the guard, risking duplicate/empty messages.

### The Fix
```diff
-    if (_sending || _fileUploading) return;
+    if (_sending || _fileUploading || _recUploading) return;
```

### Files to Edit
- `/lib/admin/mail_topic_thread_screen.dart` line 2231
- `/lib/admin/admin_teacher_mail_thread_screen.dart` line 1175

**Effort: 2 minutes per file**

---

## Fix 2 (HIGH): Search `onChanged` triggers full rebuild on every keystroke

### The Problem
In `teacher` (line 4380) and `learner` (line 2623):
```dart
onChanged: (_) => setState(() {}),
```
Every keystroke in the search field calls `setState()`, which causes the `StreamBuilder` to rebuild, re-parsing all 300 messages from Firebase, re-filtering them, and rebuilding the `ListView.builder`.

### The Fix
Replace `onChanged` with a `TextEditingController` listener with a debounce timer:

**A) Add a Timer field** near the other state fields:
```dart
Timer? _searchDebounce;
```

**B) In `initState`**, add the listener:
```dart
_searchC.addListener(_onSearchChanged);
```

**C) Add the handler method**:
```dart
void _onSearchChanged() {
  _searchDebounce?.cancel();
  _searchDebounce = Timer(const Duration(milliseconds: 200), () {
    if (mounted) setState(() {});
  });
}
```

**D) Replace `onChanged`**:
```diff
-                onChanged: (_) => setState(() {}),
+                // handled by _searchC listener with debounce
```

**E) In `dispose()`**, cancel the timer:
```dart
_searchDebounce?.cancel();
```

### Files to Edit
- `/lib/teacher/teacher_mail_thread_screen.dart` — add field (~line 141), add listener in initState (~line 221), add method, replace onChanged (line 4380), dispose (~line 278)
- `/lib/learner/learner_mail_thread_screen.dart` — same pattern

**Effort: 10 minutes per file**

---

## Fix 3 (HIGH): Migrate from `.onValue` to `.onChildAdded`+`.onChildChanged`

### The Problem
Currently all 4 files use:
```dart
_msgStream = _msgsRef
    .orderByChild('createdAt')
    .limitToLast(_messageWindowSize)
    .onValue
    .asBroadcastStream();
```
`.onValue` returns ALL 300 messages on every single change. Every incoming message forces a full re-parse of all 300 and a `StreamBuilder` rebuild.

### The Approach
Switch to a **dual-phase loading**:
1. **Initial load**: `.once()` fires once with all messages (1 rebuild)
2. **Incremental listener**: `.onChildAdded` fires only for each new message (1 rebuild per new message)
3. **Update listener**: `.onChildChanged` fires for edits/reactions (selective update)

### Detailed Steps per File

#### Step A: Replace `_msgStream` with a local `List<_MailMsg>`
```dart
// Remove:
// Stream<DatabaseEvent> _msgStream;

// Add:
List<_MailMsg> _allMessages = [];
StreamSubscription<DatabaseEvent>? _childAddedSub;
StreamSubscription<DatabaseEvent>? _childChangedSub;
bool _initialLoadDone = false;
```

#### Step B: Replace initState stream setup
```dart
// OLD:
_msgStream = _msgsRef
    .orderByChild('createdAt')
    .limitToLast(_messageWindowSize)
    .onValue
    .asBroadcastStream();

// NEW:
void _setupMessageListener() {
  // 1. Initial bulk load
  _msgsRef
      .orderByChild('createdAt')
      .limitToLast(_messageWindowSize)
      .once()
      .then((event) {
    if (!mounted) return;
    final msgs = _parseMessages(event.snapshot.value);
    setState(() {
      _allMessages = msgs;
      _visibleMessages = _applyLocalSearch(msgs);
      _initialLoadDone = true;
    });
    unawaited(_warmSenderIdentities(msgs.map((m) => m.fromUid)));
    unawaited(_markMessagesSeen(msgs));
  });

  // 2. Listen for new messages
  _childAddedSub = _msgsRef
      .orderByChild('createdAt')
      .limitToLast(1) // only the latest child
      .onChildAdded
      .skip(1) // skip the first event (already loaded via .once())
      .listen((event) {
    if (!mounted) return;
    final msg = _MailMsg.fromMap(
      event.snapshot.key!,
      Map<String, dynamic>.from(event.snapshot.value as Map),
    );
    setState(() {
      _allMessages.add(msg);
      _allMessages.sort((a, b) => b.createdAtMs.compareTo(a.createdAtMs));
      _visibleMessages = _applyLocalSearch(_allMessages);
    });
    _warmSenderIdentities([msg.fromUid]);
    _markMessagesSeen([msg]);
  });

  // 3. Listen for changes (reactions, deletions)
  _childChangedSub = _msgsRef
      .orderByChild('createdAt')
      .limitToLast(_messageWindowSize)
      .onChildChanged
      .listen((event) {
    if (!mounted) return;
    final id = event.snapshot.key!;
    final data = Map<String, dynamic>.from(event.snapshot.value as Map);
    final idx = _allMessages.indexWhere((m) => m.id == id);
    if (idx == -1) return;
    final updated = _MailMsg.fromMap(id, data);
    setState(() {
      _allMessages[idx] = updated;
      _visibleMessages = _applyLocalSearch(_allMessages);
    });
  });
}
```

#### Step C: Replace StreamBuilder
Replace the entire `StreamBuilder<DatabaseEvent>(...)` with:
```dart
if (!_initialLoadDone) {
  return const Center(child: CircularProgressIndicator());
}
if (_allMessages.isEmpty) {
  return const Center(child: Text('No mail yet.'));
}
final msgs = _visibleMessages; // already filtered by _applyLocalSearch
if (msgs.isEmpty) {
  return const Center(child: Text('No results in this thread.'));
}
return ListView.builder(
  ...
);
```

#### Step D: Update `_applyLocalSearch` 
Ensure this method filters `_allMessages` based on `_searchC.text` and returns the filtered list:
```dart
List<_MailMsg> _applyLocalSearch(List<_MailMsg> msgs) {
  final q = _searchC.text.trim().toLowerCase();
  if (q.isEmpty) return msgs;
  return msgs.where((m) => m.body.toLowerCase().contains(q)).toList();
}
```

#### Step E: Update `_visibleMessages` usage
Remove `_visibleMessages = msgs;` from the old StreamBuilder. `_visibleMessages` should now be a derived getter or set by `_applyLocalSearch`:
```dart
List<_MailMsg> get _visibleMessages => _applyLocalSearch(_allMessages);
```
Or keep it as a field but update it in `setState` calls.

#### Step F: In `dispose()`
```dart
_childAddedSub?.cancel();
_childChangedSub?.cancel();
```

### Teacher-Specific Note
Teacher file has an additional `_msgStream.asBroadcastStream()` call. Remove the broadcast entirely since we no longer use multiple listeners on the stream.

### Files to Edit
All 4 files — same pattern with minor adjustments per file.

**Effort: 45-60 minutes per file** (significant refactor but high performance impact)

---

## Fix 4 (HIGH): Remove `SelectionArea` from admin screens

### The Problem
Both admin screens wrap their body in `SelectionArea`:
```dart
body: adminWebBodyFrame(
  child: SelectionArea(  // ← this wrapper
    child: Column(
      children: [
        ...
      ],
    ),
  ),
),
```
`SelectionArea` intercepts long-press gestures for text selection, conflicting with `GestureDetector.onLongPress` used for message selection mode. Since we already set `MarkdownBody(selectable: false)`, the `SelectionArea` provides no additional value and breaks long-press selection.

### The Fix
Simply remove the `SelectionArea` wrapper:

```diff
  body: adminWebBodyFrame(
    context: context,
    maxWidth: 1500,
-   child: SelectionArea(
-     child: Column(
+   child: Column(
      children: [
        if (_subject.trim().isNotEmpty)
          ...
      ],
    ),
-   ),
  ),
```

### Files to Edit
- `/lib/admin/mail_topic_thread_screen.dart` — remove line 2510 `SelectionArea(` and its closing `)` match at line ~2540
- `/lib/admin/admin_teacher_mail_thread_screen.dart` — remove line 2248 `SelectionArea(` and its closing `)` match at line ~2276

**Effort: 2 minutes per file**

---

## Fix 5 (HIGH): Verify `_markRead` Transaction Safety

### Background
The analysis flagged that admin screens use `update()` instead of `runTransaction()` for `_markRead`. Since `mail_state/{uid}/{threadId}/lastReadAt` is per-user (only the current user writes to it), concurrent write conflicts from different devices of the same user are unlikely.

### Verification Needed
Read `_markRead` in both admin files and confirm whether it writes to a user-specific path (`mail_state/{meUid}/...`) or a shared path. If it's per-user, this is a false alarm and no fix is needed. If it writes to a shared counter (`mail_index/{uid}/unreadCount`), it needs a transaction.

### Action
1. Read and verify the `_markRead` implementations in admin files (approx 20 lines each)
2. If per-user path only: **Close as not a bug**  
3. If shared counter: **Replace `update()` with `runTransaction()`**

**Effort: 5 minutes verification**

---

## Fix 6 (MEDIUM): `_safeNetworkUrl` double-encoding in teacher

### The Problem
Teacher file line 106-108:
```dart
final u1 = Uri.tryParse(s);
if (u1 == null) return Uri.encodeFull(s);
return u1.toString();
```
`Uri.encodeFull` re-encodes already-encoded URLs (e.g., `%20` → `%2520`). Other files use `Uri.tryParse(s)?.toString() ?? Uri.encodeFull(s)` which normalizes first, then falls back to encoding.

### The Fix
```diff
-    if (u1 == null) return Uri.encodeFull(s);
+    if (u1 == null) return Uri.tryParse(s)?.toString() ?? Uri.encodeFull(s);
      return u1.toString();
```

Or simply:
```diff
-    if (u1 == null) return Uri.encodeFull(s);
-    return u1.toString();
+    return Uri.tryParse(s)?.toString() ?? Uri.encodeFull(s);
```

### Files to Edit
- `/lib/teacher/teacher_mail_thread_screen.dart` line 106-108

**Effort: 1 minute**

---

## Implementation Order

| Order | Fix | Effort | Risk |
|-------|-----|--------|------|
| 1 | Fix 1: `_recUploading` guard | 2 min/file | Low |
| 2 | Fix 4: Remove `SelectionArea` | 2 min/file | Low |
| 3 | Fix 5: Verify `_markRead` | 5 min | None |
| 4 | Fix 6: `_safeNetworkUrl` | 1 min | Low |
| 5 | Fix 2: Search debounce | 10 min/file | Low |
| 6 | Fix 3: `.onChildAdded` migration | 45-60 min/file | Medium |

---

## Verification

After all changes:
```bash
flutter analyze lib/admin/mail_topic_thread_screen.dart lib/admin/admin_teacher_mail_thread_screen.dart lib/teacher/teacher_mail_thread_screen.dart lib/learner/learner_mail_thread_screen.dart
```
Check for zero new errors/warnings.
