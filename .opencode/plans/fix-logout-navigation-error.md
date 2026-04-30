# Fix Intermittent Red Error on Logout / Back Navigation

## Problem
Intermittent red screen error on Android when logging out or navigating back from screens.

## Root Causes

### 1. `lib/auth/auth_gate.dart:77` — Buggy `nav.mounted` check
`NavigatorState`'s `mounted` property is not reliably accessible in this context. The navigator can become unmounted between the null check and `popUntil()` call.

### 2. `lib/shared/app_feedback.dart:298` — Overlay removal not guarded
`entry.remove()` in the `finally` block can throw if the overlay was already cleaned up by the framework during logout's widget tree rebuild.

### 3. Race condition: `AppLoading.run()` + `signOut()`
`signOut()` is called inside `AppLoading.run()`, which triggers `authStateChanges()` and rebuilds `AuthGate` while the loading overlay is still showing.

## Fixes

### Fix 1: `lib/auth/auth_gate.dart` — Remove `nav.mounted` check
The try-catch already wraps `popUntil`, so the extra `nav.mounted` check is redundant and buggy. Just check `nav != null`.

**Line 77: Change from:**
```dart
if (nav != null && nav.mounted) {
```
**To:**
```dart
if (nav != null) {
```

### Fix 2: `lib/shared/app_feedback.dart` — Guard overlay removal
Wrap `entry.remove()` in a try-catch to handle the case where the overlay was already cleaned up.

**Lines 295-299: Change from:**
```dart
try {
  return await task();
} finally {
  entry.remove();
}
```
**To:**
```dart
try {
  return await task();
} finally {
  try {
    entry.remove();
  } catch (_) {}
}
```

### Fix 3: `lib/learner/learner_home.dart` — Restructure logout
Move `signOut()` outside of `AppLoading.run()` to prevent the race condition. Show the loading overlay while doing prep work, then dismiss it before signing out.

**Lines 327-362: Change from:**
```dart
Future<void> _logout(BuildContext context) async {
  await AppLoading.run(
    context,
    () async {
      final uid = FirebaseAuth.instance.currentUser?.uid;

      await SessionManager.stopListening();

      await FirebaseAuth.instance.signOut();

      unawaited(() async {
        if (uid != null && uid.isNotEmpty) {
          try {
            // intentionally empty (your original)
          } catch (_) {}
        }

        try {
          await FirebaseMessaging.instance.deleteToken();
        } catch (_) {}

        if (uid != null && uid.isNotEmpty) {
          try {
            await FirebaseDatabase.instance.ref('fcm_tokens/$uid').remove();
          } catch (_) {}
        }

        try {
          await appThemeController.resetToDefault();
        } catch (_) {}
      }());
    },
    message: 'Logging out...',
    isLogout: true,
  );
}
```
**To:**
```dart
Future<void> _logout(BuildContext context) async {
  final uid = FirebaseAuth.instance.currentUser?.uid;

  await AppLoading.run(
    context,
    () async {
      await SessionManager.stopListening();
    },
    message: 'Logging out...',
    isLogout: true,
  );

  // signOut() after overlay is removed to avoid race with AuthGate rebuild
  await FirebaseAuth.instance.signOut();

  unawaited(() async {
    try {
      await FirebaseMessaging.instance.deleteToken();
    } catch (_) {}

    if (uid != null && uid.isNotEmpty) {
      try {
        await FirebaseDatabase.instance.ref('fcm_tokens/$uid').remove();
      } catch (_) {}
    }

    try {
      await appThemeController.resetToDefault();
    } catch (_) {}
  }());
}
```

### Fix 4: `lib/teacher/teacher_home.dart` — Same logout restructure
**Lines 381-408: Change from:**
```dart
Future<void> _logout(BuildContext context) async {
  await AppLoading.run(
    context,
    () async {
      final userId = FirebaseAuth.instance.currentUser?.uid;

      await SessionManager.stopListening();

      await FirebaseAuth.instance.signOut();

      unawaited(() async {
        try {
          if (userId != null && userId.isNotEmpty) {
            await FirebaseDatabase.instance
                .ref('fcm_tokens/$userId')
                .remove();
          }
        } catch (_) {}

        try {
          await appThemeController.resetToDefault();
        } catch (_) {}
      }());
    },
    message: 'Logging out...',
    isLogout: true,
  );
}
```
**To:**
```dart
Future<void> _logout(BuildContext context) async {
  final userId = FirebaseAuth.instance.currentUser?.uid;

  await AppLoading.run(
    context,
    () async {
      await SessionManager.stopListening();
    },
    message: 'Logging out...',
    isLogout: true,
  );

  // signOut() after overlay is removed to avoid race with AuthGate rebuild
  await FirebaseAuth.instance.signOut();

  unawaited(() async {
    if (userId != null && userId.isNotEmpty) {
      try {
        await FirebaseDatabase.instance
            .ref('fcm_tokens/$userId')
            .remove();
      } catch (_) {}
    }

    try {
      await appThemeController.resetToDefault();
    } catch (_) {}
  }());
}
```

### Fix 5: `lib/admin/admin_home.dart` — Same logout restructure
**Lines 241-270: Change from:**
```dart
Future<void> _logout(BuildContext context) async {
  await AppLoading.run(
    context,
    () async {
      final userId = FirebaseAuth.instance.currentUser?.uid;

      // ✅ stop "single device" listener
      await SessionManager.stopListening();

      await FirebaseAuth.instance.signOut();

      unawaited(() async {
        // ✅ remove FCM token record
        try {
          if (userId != null && userId.isNotEmpty) {
            await FirebaseDatabase.instance
                .ref('fcm_tokens/$userId')
                .remove();
          }
        } catch (_) {}

        try {
          await appThemeController.resetToDefault();
        } catch (_) {}
      }());
    },
    message: 'Logging out...',
    isLogout: true,
  );
}
```
**To:**
```dart
Future<void> _logout(BuildContext context) async {
  final userId = FirebaseAuth.instance.currentUser?.uid;

  await AppLoading.run(
    context,
    () async {
      // ✅ stop "single device" listener
      await SessionManager.stopListening();
    },
    message: 'Logging out...',
    isLogout: true,
  );

  // signOut() after overlay is removed to avoid race with AuthGate rebuild
  await FirebaseAuth.instance.signOut();

  unawaited(() async {
    // ✅ remove FCM token record
    if (userId != null && userId.isNotEmpty) {
      try {
        await FirebaseDatabase.instance
            .ref('fcm_tokens/$userId')
            .remove();
      } catch (_) {}
    }

    try {
      await appThemeController.resetToDefault();
    } catch (_) {}
  }());
}
```

## Summary of Changes
| File | Change |
|------|--------|
| `lib/auth/auth_gate.dart` | Remove `nav.mounted` check (line 77) |
| `lib/shared/app_feedback.dart` | Wrap `entry.remove()` in try-catch |
| `lib/learner/learner_home.dart` | Move `signOut()` outside `AppLoading.run()` |
| `lib/teacher/teacher_home.dart` | Move `signOut()` outside `AppLoading.run()` |
| `lib/admin/admin_home.dart` | Move `signOut()` outside `AppLoading.run()` |
