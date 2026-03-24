import 'package:flutter/material.dart';

import 'app_tour_guide.dart';

class AdminTourHint extends AppTourHint {
  const AdminTourHint({
    required super.title,
    required super.line,
    super.targetKey,
    super.highlightShape = AppTourHighlightShape.auto,
  });

  AppTourHint toBase() {
    return AppTourHint(
      title: title,
      line: line,
      targetKey: targetKey,
      highlightShape: highlightShape,
    );
  }
}

class AdminTourGuide {
  static const String _scopeKey = 'admin';
  static const AppTourTexts _texts = AppTourTexts.arabic();

  static void schedule(
    BuildContext context, {
    required String screenId,
    required List<AdminTourHint> hints,
    bool isQuickStart = false,
  }) {
    AppTourGuide.schedule(
      context,
      scopeKey: _scopeKey,
      screenId: screenId,
      hints: _toBaseHints(hints),
      texts: _texts,
      isQuickStart: isQuickStart,
    );
  }

  static void scheduleSimple(
    BuildContext context, {
    required String screenId,
    required String title,
    required String line,
  }) {
    schedule(
      context,
      screenId: screenId,
      hints: [AdminTourHint(title: title, line: line)],
    );
  }

  static Future<void> resetAll() {
    return AppTourGuide.resetAll(_scopeKey);
  }

  static Future<bool> shouldShow(
    String screenId, {
    bool isQuickStart = false,
  }) {
    return AppTourGuide.shouldShow(
      _scopeKey,
      screenId,
      isQuickStart: isQuickStart,
    );
  }

  static Future<void> startNow(
    BuildContext context, {
    required String screenId,
    required List<AdminTourHint> hints,
    bool isQuickStart = false,
  }) {
    return AppTourGuide.startNow(
      context,
      scopeKey: _scopeKey,
      screenId: screenId,
      hints: _toBaseHints(hints),
      texts: _texts,
      isQuickStart: isQuickStart,
    );
  }

  static Future<void> maybeStart(
    BuildContext context, {
    required String screenId,
    required List<AdminTourHint> hints,
    bool isQuickStart = false,
    bool force = false,
  }) {
    return AppTourGuide.maybeStart(
      context,
      scopeKey: _scopeKey,
      screenId: screenId,
      hints: _toBaseHints(hints),
      texts: _texts,
      isQuickStart: isQuickStart,
      force: force,
    );
  }

  static List<AppTourHint> _toBaseHints(List<AdminTourHint> hints) {
    return hints.map((h) => h.toBase()).toList(growable: false);
  }
}
