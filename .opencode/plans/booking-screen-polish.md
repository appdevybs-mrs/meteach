# Booking Screen Arabic/UI Polish Plan

## File
`lib/learner/learner_booking_screen.dart`

## Change 1 — Translation toggle in AppBar
**Remove** from `_buildLessonChoiceStep()` (eliminate the `OutlinedButton.icon` inside the `Row` at the title, simplify to a `Center` wrapping the `Text` alone).

**Add** to `build()` → `Scaffold` → `AppBar` → `actions` (right before the `?` button at line ~7270):
```dart
IconButton(
  tooltip: lessonChoiceArabic ? 'English' : 'العربية',
  onPressed: () => setState(() => lessonChoiceArabic = !lessonChoiceArabic),
  icon: Icon(Icons.translate_rounded, color: palette.primary),
),
```

## Change 2 — RTL "period" punctuation + Directionality wrappers
Wrap the following methods' root content in `Directionality(textDirection: isAr ? TextDirection.rtl : TextDirection.ltr)`:
- `_buildScheduleHeader()` — wrap the returned `Container`
- `_buildScheduleStep()` — wrap the returned `Column`
- `_buildConfirmStep()` — wrap the returned `Column`
- `_buildByTeacherPath()` — wrap the returned `Column`
- `_buildByDayPath()` — wrap the returned `Column`

This ensures all trailing periods `.` render on the correct side for Arabic.

## Change 3 — Redesign confirm step card
Replace the white `Container` card (lines 6993–7140) with a **deep gradient card** (teal `#0E7C86` → `#0A5E66` gradient, same as `_buildContinueLearningCard`):
- Row at top: course title (white, bold) + "Change session" `OutlinedButton` (white border, white text)
- `_buildSessionLinePill` with `onPrimary: true` for the session label
- Teacher avatar + name row (white text)
- Date/time row: `"${_friendlyDate(selectedDay!)} • $selectedTime"` (white text)
- Expand/collapse session objective toggle (styled for dark bg: chevron icon, label in white)
- AnimatedSize section for objective text (white text, semi-transparent bg)

## Change 4 — Confirm step Arabic translations
- `"Confirm your booking"` → `isAr ? 'تأكيد الحجز' : 'Confirm your booking'`
- `"Back"` → `isAr ? 'رجوع' : 'Back'`
- `"Confirm booking"` → `isAr ? 'تأكيد' : 'Confirm booking'`
- Wrap buttons `Row` in `Directionality` or use `textDirection`

## Change 5 — Translate By Teacher / By Day
At all 4 call sites (lines 6914, 6924, 6935, 6941):
```dart
label: isAr ? 'حسب المعلم' : 'By Teacher',
label: isAr ? 'حسب التوقيت' : 'By Day',
```

## Change 6 — Full Arabic translations for scheduling step
| Location | English | Arabic |
|---|---|---|
| `_buildScheduleHeader` — "Change lesson" | `isAr ? 'تغيير الدرس' : 'Change lesson'` |
| `_buildByTeacherPath` — step 1 label | `isAr ? 'اختر معلم' : 'Choose a teacher'` |
| `_buildByTeacherPath` — step 2 label | `isAr ? 'اختر يوم' : 'Choose a day'` |
| `_buildByTeacherPath` — step 3 label | `isAr ? 'اختر وقت' : 'Choose a time'` |
| `_buildByTeacherPath` — "Select" button | `isAr ? 'اختيار' : 'Select'` |
| `_buildByTeacherPath` — "Locked" button | `isAr ? 'مقفول' : 'Locked'` |
| `_buildByTeacherPath` — "Continue to confirm" | `isAr ? 'متابعة للتأكيد' : 'Continue to confirm'` |
| `_buildByDayPath` — step 1 label | `isAr ? 'اختر يوم' : 'Choose a day'` |
| `_buildByDayPath` — step 2 label | `isAr ? 'اختر وقت' : 'Choose a time'` |
| `_buildByDayPath` — step 3 label | `isAr ? 'اختر معلم' : 'Choose a teacher'` |
| `_buildByDayPath` — "Select" button | `isAr ? 'اختيار' : 'Select'` |
| `_buildByDayPath` — "Locked" button | `isAr ? 'مقفول' : 'Locked'` |
| Suggested section title | `isAr ? 'مقترح (نفس المستوى)' : 'Suggested (same level)'` |
| "Join" badge | `isAr ? 'انضمام' : 'Join'` (or keep as-is — short enough) |
| "Join + switch" badge | `isAr ? 'انضمام + تبديل' : 'Join + switch'` |
| `_slotStateBadge` — "Booked" / "Unavailable" / "Closed" / "Book" | Arabic equivalents where applicable |

## Change 7 — Bottom sheet covered by phone nav bar
In `_openSessionBookingSheet()`, wrap the `Column` content in `SingleChildScrollView` and add bottom padding:
```dart
builder: (_) => Container(
  ...
  padding: EdgeInsets.fromLTRB(16, 14, 16, 18 + MediaQuery.of(context).viewInsets.bottom),
  child: SingleChildScrollView(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      ...
    ),
  ),
),
```

## Verification
- Run `flutter analyze lib/learner/learner_booking_screen.dart` — zero errors/warnings
