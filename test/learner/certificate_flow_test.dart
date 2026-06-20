import 'package:flutter_test/flutter_test.dart';

/// Mirrors the _courseCertificateUnlocked logic:
/// Certificate is unlocked when _totalUnits > 0 && _completedUnits == _totalUnits
/// A unit is completed when ALL its sessions are completed
/// Session completion uses OR logic (video OR materials)
bool isCertificateUnlocked({
  required int totalUnits,
  required int completedUnits,
}) {
  return totalUnits > 0 && completedUnits == totalUnits;
}

/// Mirrors _isUnitCompleted: a unit is done when all sessions are completed
bool isUnitCompleted({
  required int totalSessions,
  required int completedSessions,
}) {
  if (totalSessions <= 0) return false;
  return completedSessions == totalSessions;
}

/// Mirrors the _resolveCompleted / _isSessionCompleted OR logic
bool isSessionCompleted({
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

void main() {
  group('Certificate unlock condition', () {
    test('locked when totalUnits is 0', () {
      expect(isCertificateUnlocked(totalUnits: 0, completedUnits: 0), false);
    });

    test('locked when not all units completed', () {
      expect(isCertificateUnlocked(totalUnits: 3, completedUnits: 2), false);
    });

    test('unlocked when all units completed', () {
      expect(isCertificateUnlocked(totalUnits: 3, completedUnits: 3), true);
    });

    test('unlocked with single unit', () {
      expect(isCertificateUnlocked(totalUnits: 1, completedUnits: 1), true);
    });
  });

  group('Unit completion condition', () {
    test('unit not completed when no sessions', () {
      expect(isUnitCompleted(totalSessions: 0, completedSessions: 0), false);
    });

    test('unit not completed when sessions remain', () {
      expect(isUnitCompleted(totalSessions: 5, completedSessions: 3), false);
    });

    test('unit completed when all sessions done', () {
      expect(isUnitCompleted(totalSessions: 5, completedSessions: 5), true);
    });
  });

  group('Session completion (OR logic) for certificate flow', () {
    test('video-only session: needs videoCompleted', () {
      expect(
        isSessionCompleted(
          requiresVideo: true, requiresMaterials: false,
          videoCompleted: true, materialsCompleted: false,
        ),
        true,
      );
      expect(
        isSessionCompleted(
          requiresVideo: true, requiresMaterials: false,
          videoCompleted: false, materialsCompleted: false,
        ),
        false,
      );
    });

    test('materials-only session: needs materialsCompleted', () {
      expect(
        isSessionCompleted(
          requiresVideo: false, requiresMaterials: true,
          videoCompleted: false, materialsCompleted: true,
        ),
        true,
      );
    });

    test('both required: OR logic — video done is sufficient for cert progress', () {
      expect(
        isSessionCompleted(
          requiresVideo: true, requiresMaterials: true,
          videoCompleted: true, materialsCompleted: false,
        ),
        true,
      );
    });
  });

  group('Integration: full unit-to-certificate chain', () {
    test('certificate unlocks when all sessions across all units complete', () {
      // Simulate 2 units, each with 3 sessions
      // Unit 1: all 3 sessions done
      // Unit 2: all 3 sessions done
      // → certificate should be unlocked

      int countCompletedSessions({
        required int totalSessions,
        required bool Function(int index) isSessionCompleted,
      }) {
        int count = 0;
        for (int i = 0; i < totalSessions; i++) {
          if (isSessionCompleted(i)) count++;
        }
        return count;
      }

      bool isUnitComplete(int total, int completed) =>
          total > 0 && completed == total;

      // Unit 1: 3 sessions, all done
      final unit1Total = 3;
      final unit1Done = countCompletedSessions(
        totalSessions: unit1Total,
        isSessionCompleted: (i) => true,
      );

      // Unit 2: 3 sessions, all done
      final unit2Total = 3;
      final unit2Done = countCompletedSessions(
        totalSessions: unit2Total,
        isSessionCompleted: (i) => true,
      );

      final completedUnits = (isUnitComplete(unit1Total, unit1Done) ? 1 : 0) +
          (isUnitComplete(unit2Total, unit2Done) ? 1 : 0);

      expect(isCertificateUnlocked(totalUnits: 2, completedUnits: completedUnits), true);
    });

    test('certificate stays locked if one session in one unit is incomplete', () {
      // Unit 1: all 3 done
      // Unit 2: only 2 of 3 done → unit not complete
      // → certificate should NOT be unlocked

      int countCompletedSessions(int total, bool Function(int) check) {
        int c = 0;
        for (int i = 0; i < total; i++) {
          if (check(i)) c++;
        }
        return c;
      }

      bool isUnitComplete(int total, int completed) =>
          total > 0 && completed == total;

      final unit1Total = 3;
      final unit1Done = countCompletedSessions(unit1Total, (i) => true);

      final unit2Total = 3;
      final unit2Done = countCompletedSessions(unit2Total, (i) => i != 0);

      final completedUnits = (isUnitComplete(unit1Total, unit1Done) ? 1 : 0) +
          (isUnitComplete(unit2Total, unit2Done) ? 1 : 0);

      expect(isCertificateUnlocked(totalUnits: 2, completedUnits: completedUnits), false);
    });
  });
}
