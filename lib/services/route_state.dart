// lib/services/route_state.dart
class RouteState {
  static String? currentMailThreadId;

  static bool get isInMailThread => currentMailThreadId != null;

  static void enterMailThread(String threadId) {
    currentMailThreadId = threadId;
  }

  static void exitMailThread(String threadId) {
    if (currentMailThreadId == threadId) {
      currentMailThreadId = null;
    }
  }
}
