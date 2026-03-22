# MeTeach

Cross-platform Flutter app for safely editing protected gradebook `.xlsx` files.

## Included Scope

- Multiplatform target: Android, iOS, Web
- Adaptive UI: mobile bottom navigation, desktop/tablet rail layout
- 8 main screens: Splash, Home, Overview, Sheet Editor, Global Search, Bulk Actions, Validation, Rules/Presets, Settings, Export
- Localization: English, French, Arabic (UI only)
- Excel import and constrained editing for columns `E:H` from row `9`
- Validation engine: empty/out-of-range scores, missing remarks, consistency checks
- Bulk tools: fill empty scores, set values, randomize values, apply remark rules
- Change tracking: undo, row reset, sheet reset, workbook restore, snapshots
- Safe export with integrity checks on sheet count and names

## Run

```bash
flutter pub get
flutter analyze
flutter test
flutter run
```

## Main Files

- `lib/main.dart`
- `lib/app.dart`
- `lib/state/app_state.dart`
- `lib/services/excel_service.dart`
- `lib/services/validation_service.dart`
- `lib/models/workbook_models.dart`
- `lib/l10n/app_localizations.dart`
