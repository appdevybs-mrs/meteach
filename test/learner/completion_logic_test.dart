import 'package:flutter_test/flutter_test.dart';

/// Mirrors the _resolveCompleted logic from recorded_course_study_screen.dart
/// Without its private prefix, so we can test it.
///
/// Both `_isSessionCompleted` and `_resolveCompleted` use the same rule:
/// - If only video required → needs videoCompleted
/// - If only materials required → needs materialsCompleted
/// - If both required → needs videoCompleted (materials cannot bypass video)
/// - If neither → completed
bool resolveCompleted({
  required bool requiresVideo,
  required bool requiresMaterials,
  required bool videoCompleted,
  required bool materialsCompleted,
}) {
  if (!requiresVideo && !requiresMaterials) return true;
  if (requiresVideo && requiresMaterials) {
    return videoCompleted;
  }
  if (requiresVideo) return videoCompleted;
  if (requiresMaterials) return materialsCompleted;
  return false;
}

/// Manual mark-done buttons should appear only when:
/// 1. Session is unlocked (isUnlocked == true)
/// 2. Session is not already completed
/// 3. Materials are required AND not yet completed
bool shouldShowMarkVideoButton({
  required bool isUnlocked,
  required bool isCompleted,
  required bool requiresVideo,
  required bool videoCompleted,
}) {
  return false;
}

bool shouldShowMarkMaterialsButton({
  required bool isUnlocked,
  required bool isCompleted,
  required bool requiresMaterials,
  required bool materialsCompleted,
}) {
  return false;
}

bool canSeekForward({required bool videoCompleted}) => videoCompleted;

bool canUsePlaybackSpeed({
  required bool videoCompleted,
  required double speed,
}) {
  return videoCompleted || speed <= 1.0;
}

bool shouldMarkVideoCompletedByWatchTime({
  required int eligibleWatchMs,
  required int durationMs,
  required int positionMs,
}) {
  return durationMs > 0 &&
      eligibleWatchMs >= durationMs &&
      positionMs >= durationMs - 1200;
}

int eligibleWatchMsAfterAttentionFailure({
  required bool completedWhenOpened,
  required int currentEligibleWatchMs,
}) {
  return completedWhenOpened ? currentEligibleWatchMs : 0;
}

void main() {
  group('_resolveCompleted (verified video required)', () {
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

    test('requires both → video is required', () {
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
        false,
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
    test(
      'Mark video button is hidden because videos require verified watch time',
      () {
        expect(
          shouldShowMarkVideoButton(
            isUnlocked: true,
            isCompleted: false,
            requiresVideo: true,
            videoCompleted: false,
          ),
          false,
        );
      },
    );

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

    test(
      'Mark materials button is hidden because reading completion is automatic',
      () {
        expect(
          shouldShowMarkMaterialsButton(
            isUnlocked: true,
            isCompleted: false,
            requiresMaterials: true,
            materialsCompleted: false,
          ),
          false,
        );
      },
    );

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

  group('Recorded video anti-skip policy', () {
    test(
      'video completes only when watch time reaches duration near the end',
      () {
        expect(
          shouldMarkVideoCompletedByWatchTime(
            eligibleWatchMs: 359000,
            durationMs: 360000,
            positionMs: 360000,
          ),
          false,
        );
        expect(
          shouldMarkVideoCompletedByWatchTime(
            eligibleWatchMs: 360000,
            durationMs: 360000,
            positionMs: 120000,
          ),
          false,
        );
        expect(
          shouldMarkVideoCompletedByWatchTime(
            eligibleWatchMs: 360000,
            durationMs: 360000,
            positionMs: 359000,
          ),
          true,
        );
      },
    );

    test('forward seek is blocked until video is completed', () {
      expect(canSeekForward(videoCompleted: false), false);
      expect(canSeekForward(videoCompleted: true), true);
    });

    test('faster playback is blocked until video is completed', () {
      expect(canUsePlaybackSpeed(videoCompleted: false, speed: 1.0), true);
      expect(canUsePlaybackSpeed(videoCompleted: false, speed: 1.25), false);
      expect(canUsePlaybackSpeed(videoCompleted: true, speed: 2.0), true);
    });

    test('missed attention check resets only unfinished attempts', () {
      expect(
        eligibleWatchMsAfterAttentionFailure(
          completedWhenOpened: false,
          currentEligibleWatchMs: 120000,
        ),
        0,
      );
      expect(
        eligibleWatchMsAfterAttentionFailure(
          completedWhenOpened: true,
          currentEligibleWatchMs: 360000,
        ),
        360000,
      );
    });
  });
}
