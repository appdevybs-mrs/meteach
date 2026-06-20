import 'package:flutter_test/flutter_test.dart';

/// Mirrors the _resolveCompleted logic from recorded_course_study_screen.dart
/// Without its private prefix, so we can test it.
///
/// Both `_isSessionCompleted` and `_resolveCompleted` use the same rule:
/// - If only video required → needs videoCompleted
/// - If only materials required → needs materialsCompleted
/// - If both required → needs videoCompleted OR materialsCompleted (OR logic)
/// - If neither → completed
bool resolveCompleted({
  required bool requiresVideo,
  required bool requiresMaterials,
  required bool videoCompleted,
  required bool materialsCompleted,
}) {
  if (!requiresVideo && !requiresMaterials) return true;
  if (requiresVideo && requiresMaterials) {
    return videoCompleted || materialsCompleted;
  }
  if (requiresVideo) return videoCompleted;
  if (requiresMaterials) return materialsCompleted;
  return false;
}

/// The new manual mark-done buttons should appear only when:
/// 1. Session is unlocked (isUnlocked == true)
/// 2. Session is not already completed
/// 3. Component (video/materials) is required AND not yet completed
bool shouldShowMarkVideoButton({
  required bool isUnlocked,
  required bool isCompleted,
  required bool requiresVideo,
  required bool videoCompleted,
}) {
  return isUnlocked && !isCompleted && requiresVideo && !videoCompleted;
}

bool shouldShowMarkMaterialsButton({
  required bool isUnlocked,
  required bool isCompleted,
  required bool requiresMaterials,
  required bool materialsCompleted,
}) {
  return isUnlocked && !isCompleted && requiresMaterials && !materialsCompleted;
}

void main() {
  group('_resolveCompleted (OR logic)', () {
    test('requires video only → videoCompleted must be true', () {
      expect(
        resolveCompleted(
          requiresVideo: true,
          requiresMaterials: false,
          videoCompleted: true,
          materialsCompleted: false,
        ),
        true,
      );
      expect(
        resolveCompleted(
          requiresVideo: true,
          requiresMaterials: false,
          videoCompleted: false,
          materialsCompleted: true,
        ),
        false,
      );
    });

    test('requires materials only → materialsCompleted must be true', () {
      expect(
        resolveCompleted(
          requiresVideo: false,
          requiresMaterials: true,
          videoCompleted: false,
          materialsCompleted: true,
        ),
        true,
      );
      expect(
        resolveCompleted(
          requiresVideo: false,
          requiresMaterials: true,
          videoCompleted: true,
          materialsCompleted: false,
        ),
        false,
      );
    });

    test('requires both → EITHER one is sufficient (OR logic)', () {
      expect(
        resolveCompleted(
          requiresVideo: true,
          requiresMaterials: true,
          videoCompleted: true,
          materialsCompleted: false,
        ),
        true,
      );
      expect(
        resolveCompleted(
          requiresVideo: true,
          requiresMaterials: true,
          videoCompleted: false,
          materialsCompleted: true,
        ),
        true,
      );
      expect(
        resolveCompleted(
          requiresVideo: true,
          requiresMaterials: true,
          videoCompleted: true,
          materialsCompleted: true,
        ),
        true,
      );
      expect(
        resolveCompleted(
          requiresVideo: true,
          requiresMaterials: true,
          videoCompleted: false,
          materialsCompleted: false,
        ),
        false,
      );
    });

    test('requires neither → always completed', () {
      expect(
        resolveCompleted(
          requiresVideo: false,
          requiresMaterials: false,
          videoCompleted: false,
          materialsCompleted: false,
        ),
        true,
      );
    });
  });

  group('Manual mark-done button visibility', () {
    test('Mark video button shown when unlocked, not completed, video required, video not done', () {
      expect(
        shouldShowMarkVideoButton(
          isUnlocked: true,
          isCompleted: false,
          requiresVideo: true,
          videoCompleted: false,
        ),
        true,
      );
    });

    test('Mark video button hidden when video already completed', () {
      expect(
        shouldShowMarkVideoButton(
          isUnlocked: true,
          isCompleted: false,
          requiresVideo: true,
          videoCompleted: true,
        ),
        false,
      );
    });

    test('Mark video button hidden when session already completed', () {
      expect(
        shouldShowMarkVideoButton(
          isUnlocked: true,
          isCompleted: true,
          requiresVideo: true,
          videoCompleted: false,
        ),
        false,
      );
    });

    test('Mark video button hidden when locked', () {
      expect(
        shouldShowMarkVideoButton(
          isUnlocked: false,
          isCompleted: false,
          requiresVideo: true,
          videoCompleted: false,
        ),
        false,
      );
    });

    test('Mark video button hidden when video not required', () {
      expect(
        shouldShowMarkVideoButton(
          isUnlocked: true,
          isCompleted: false,
          requiresVideo: false,
          videoCompleted: false,
        ),
        false,
      );
    });

    test('Mark materials button shown when unlocked, not completed, materials required, materials not done', () {
      expect(
        shouldShowMarkMaterialsButton(
          isUnlocked: true,
          isCompleted: false,
          requiresMaterials: true,
          materialsCompleted: false,
        ),
        true,
      );
    });

    test('Mark materials button hidden when materials already completed', () {
      expect(
        shouldShowMarkMaterialsButton(
          isUnlocked: true,
          isCompleted: false,
          requiresMaterials: true,
          materialsCompleted: true,
        ),
        false,
      );
    });
  });
}
