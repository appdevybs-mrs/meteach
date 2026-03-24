import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppTourHint {
  const AppTourHint({
    required this.title,
    required this.line,
    this.targetKey,
    this.highlightShape = AppTourHighlightShape.auto,
  });

  final String title;
  final String line;
  final GlobalKey? targetKey;
  final AppTourHighlightShape highlightShape;
}

enum AppTourHighlightShape { auto, circle, rectangle, roundedRectangle, fullscreen }

class AppTourTexts {
  const AppTourTexts({
    required this.direction,
    required this.skip,
    required this.next,
    required this.done,
    required this.dontShowAgain,
  });

  const AppTourTexts.arabic()
    : direction = TextDirection.rtl,
      skip = 'تخطي',
      next = 'التالي',
      done = 'تم',
      dontShowAgain = 'عدم إظهار الإرشادات مرة أخرى';

  const AppTourTexts.english()
    : direction = TextDirection.ltr,
      skip = 'Skip',
      next = 'Next',
      done = 'Done',
      dontShowAgain = 'Do not show these hints again';

  final TextDirection direction;
  final String skip;
  final String next;
  final String done;
  final String dontShowAgain;
}

enum _TourStepAction { next, skip, done }

class AppTourGuide {
  static final Set<String> _shownThisSession = <String>{};
  static final Set<String> _runningScopes = <String>{};
  static int _pauseCount = 0;

  static void pause() {
    _pauseCount += 1;
  }

  static void resume() {
    if (_pauseCount > 0) {
      _pauseCount -= 1;
    }
  }

  static bool get isPaused => _pauseCount > 0;

  static void schedule(
    BuildContext context, {
    required String scopeKey,
    required String screenId,
    required List<AppTourHint> hints,
    required AppTourTexts texts,
    bool isQuickStart = false,
    bool requiresQuickStart = false,
  }) {
    if (hints.isEmpty) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      maybeStart(
        context,
        scopeKey: scopeKey,
        screenId: screenId,
        hints: hints,
        texts: texts,
        isQuickStart: isQuickStart,
        requiresQuickStart: requiresQuickStart,
      );
    });
  }

  static Future<void> resetAll(String scopeKey) async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys();
    final seenPrefix = _seenPrefix(scopeKey);

    await prefs.remove(_hideAllPref(scopeKey));
    await prefs.remove(_quickStartDonePref(scopeKey));
    for (final key in keys) {
      if (key.startsWith(seenPrefix)) {
        await prefs.remove(key);
      }
    }

    _shownThisSession.removeWhere((k) => k.startsWith('$scopeKey|'));
  }

  static Future<bool> shouldShow(
    String scopeKey,
    String screenId, {
    bool isQuickStart = false,
    bool requiresQuickStart = false,
  }) async {
    if (_runningScopes.contains(scopeKey)) return false;

    final sessionKey = _sessionKey(scopeKey, screenId);
    if (_shownThisSession.contains(sessionKey)) return false;

    final prefs = await SharedPreferences.getInstance();
    final hideAll = prefs.getBool(_hideAllPref(scopeKey)) ?? false;
    if (hideAll) return false;

    final quickDone = prefs.getBool(_quickStartDonePref(scopeKey)) ?? false;
    if (requiresQuickStart) {
      if (!isQuickStart && !quickDone) return false;
      if (isQuickStart && quickDone) return false;
    }

    final seenBefore = prefs.getBool(_seenKey(scopeKey, screenId)) ?? false;
    return !seenBefore;
  }

  static Future<void> startNow(
    BuildContext context, {
    required String scopeKey,
    required String screenId,
    required List<AppTourHint> hints,
    required AppTourTexts texts,
    bool isQuickStart = false,
    bool requiresQuickStart = false,
  }) {
    return maybeStart(
      context,
      scopeKey: scopeKey,
      screenId: screenId,
      hints: hints,
      texts: texts,
      isQuickStart: isQuickStart,
      requiresQuickStart: requiresQuickStart,
      force: true,
    );
  }

  static Future<void> maybeStart(
    BuildContext context, {
    required String scopeKey,
    required String screenId,
    required List<AppTourHint> hints,
    required AppTourTexts texts,
    bool isQuickStart = false,
    bool requiresQuickStart = false,
    bool force = false,
  }) async {
    if (!context.mounted) return;
    if (hints.isEmpty) return;
    await _waitUntilUnpaused(context);
    if (!context.mounted) return;
    if (_runningScopes.contains(scopeKey)) return;

    final sessionKey = _sessionKey(scopeKey, screenId);
    if (!force && _shownThisSession.contains(sessionKey)) return;

    final prefs = await SharedPreferences.getInstance();
    if (!context.mounted) return;

    final hideAll = prefs.getBool(_hideAllPref(scopeKey)) ?? false;
    if (hideAll && !force) return;

    final quickDone = prefs.getBool(_quickStartDonePref(scopeKey)) ?? false;
    if (requiresQuickStart) {
      if (!isQuickStart && !quickDone && !force) return;
      if (isQuickStart && quickDone && !force) return;
    }

    final seenBefore = prefs.getBool(_seenKey(scopeKey, screenId)) ?? false;
    if (!force && seenBefore) return;

    _shownThisSession.add(sessionKey);
    _runningScopes.add(scopeKey);

    try {
      var dontShowAgain = false;
      var index = 0;

      while (index < hints.length && context.mounted) {
        final current = hints[index];
        final isLast = index == hints.length - 1;

        final action = await showDialog<_TourStepAction>(
          context: context,
          barrierDismissible: false,
          barrierColor: Colors.transparent,
          builder: (dialogContext) {
            return _AppTourStepDialog(
              hint: current,
              texts: texts,
              index: index,
              total: hints.length,
              isLast: isLast,
              initialDontShowAgain: dontShowAgain,
              onDontShowAgainChanged: (v) => dontShowAgain = v,
            );
          },
        );

        if (action == _TourStepAction.skip ||
            action == _TourStepAction.done ||
            action == null) {
          break;
        }

        index += 1;
      }

      await prefs.setBool(_seenKey(scopeKey, screenId), true);
      if (isQuickStart) {
        await prefs.setBool(_quickStartDonePref(scopeKey), true);
      }

      if (dontShowAgain) {
        await prefs.setBool(_hideAllPref(scopeKey), true);
      }
    } finally {
      _runningScopes.remove(scopeKey);
    }
  }

  static Future<void> _waitUntilUnpaused(BuildContext context) async {
    var ticks = 0;
    while (isPaused && context.mounted && ticks < 240) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      ticks += 1;
    }
  }

  static String _sessionKey(String scopeKey, String screenId) {
    return '$scopeKey|$screenId';
  }

  static String _hideAllPref(String scopeKey) => '${scopeKey}_tour_hide_all';

  static String _quickStartDonePref(String scopeKey) =>
      '${scopeKey}_tour_quick_start_done';

  static String _seenPrefix(String scopeKey) => '${scopeKey}_tour_seen_';

  static String _seenKey(String scopeKey, String screenId) =>
      '${_seenPrefix(scopeKey)}$screenId';
}

class _AppTourStepDialog extends StatefulWidget {
  const _AppTourStepDialog({
    required this.hint,
    required this.texts,
    required this.index,
    required this.total,
    required this.isLast,
    required this.initialDontShowAgain,
    required this.onDontShowAgainChanged,
  });

  final AppTourHint hint;
  final AppTourTexts texts;
  final int index;
  final int total;
  final bool isLast;
  final bool initialDontShowAgain;
  final ValueChanged<bool> onDontShowAgainChanged;

  @override
  State<_AppTourStepDialog> createState() => _AppTourStepDialogState();
}

class _AppTourStepDialogState extends State<_AppTourStepDialog> {
  late bool _dontShowAgain;

  @override
  void initState() {
    super.initState();
    _dontShowAgain = widget.initialDontShowAgain;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensureTargetVisible();
    });
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final size = media.size;
    final targetRect = _targetRect(widget.hint.targetKey);
    final highlightRect = _highlightRect(size, targetRect);
    final highlightShape = _resolveHighlightShape(targetRect);
    final cardPos = _cardPosition(
      size: size,
      media: media,
      highlightRect: highlightRect,
      shape: highlightShape,
    );

    final fingerPos = _fingerPosition(
      size: size,
      highlightRect: highlightRect,
      shape: highlightShape,
    );

    return Directionality(
      textDirection: widget.texts.direction,
      child: Material(
        color: Colors.transparent,
        child: Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _CoachOverlayPainter(
                  highlightRect: highlightRect,
                  shape: highlightShape,
                ),
              ),
            ),
            if (fingerPos != null)
              Positioned(
                left: fingerPos.dx,
                top: fingerPos.dy,
                child: const Icon(
                  Icons.touch_app_rounded,
                  size: 34,
                  color: Color(0xFFF98D28),
                ),
              ),
            Positioned(
              left: 12,
              right: 12,
              top: cardPos.top,
              bottom: cardPos.bottom,
              child: _messageCard(context),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _ensureTargetVisible() async {
    final key = widget.hint.targetKey;
    if (key == null) return;
    final ctx = key.currentContext;
    if (ctx == null) return;
    try {
      await Scrollable.ensureVisible(
        ctx,
        alignment: 0.5,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
      if (mounted) {
        setState(() {});
      }
    } catch (_) {
      // Ignore if target has no scrollable ancestor.
    }
  }

  Rect? _targetRect(GlobalKey? key) {
    final ctx = key?.currentContext;
    if (ctx == null) return null;

    final ro = ctx.findRenderObject();
    if (ro is! RenderBox || !ro.hasSize) return null;

    final origin = ro.localToGlobal(Offset.zero);
    return origin & ro.size;
  }

  AppTourHighlightShape _resolveHighlightShape(Rect? targetRect) {
    if (widget.hint.highlightShape != AppTourHighlightShape.auto) {
      return widget.hint.highlightShape;
    }
    if (targetRect == null) {
      return AppTourHighlightShape.fullscreen;
    }

    final maxSide = math.max(targetRect.width, targetRect.height);
    final minSide = math.min(targetRect.width, targetRect.height);
    final almostSquare = maxSide <= (minSide * 1.35);
    final compact = maxSide <= 80;

    if (almostSquare && compact) {
      return AppTourHighlightShape.circle;
    }
    return AppTourHighlightShape.roundedRectangle;
  }

  Rect _highlightRect(Size size, Rect? targetRect) {
    final shape = _resolveHighlightShape(targetRect);
    if (shape == AppTourHighlightShape.fullscreen || targetRect == null) {
      return Rect.fromLTWH(8, 8, size.width - 16, size.height - 16);
    }

    const dx = 10.0;
    const dy = 8.0;
    return Rect.fromLTRB(
      (targetRect.left - dx).clamp(4.0, size.width - 4.0),
      (targetRect.top - dy).clamp(4.0, size.height - 4.0),
      (targetRect.right + dx).clamp(4.0, size.width - 4.0),
      (targetRect.bottom + dy).clamp(4.0, size.height - 4.0),
    );
  }

  Offset? _fingerPosition({
    required Size size,
    required Rect highlightRect,
    required AppTourHighlightShape shape,
  }) {
    if (shape == AppTourHighlightShape.fullscreen) {
      final x = highlightRect.right - 28;
      final y = highlightRect.top + 16;
      return Offset(x.clamp(8, size.width - 42), y.clamp(8, size.height - 160));
    }

    final canPlaceAbove = highlightRect.top >= 40;
    final canPlaceBelow = highlightRect.bottom <= size.height - 68;

    double x;
    double y;
    if (canPlaceAbove) {
      x = highlightRect.right - 14;
      y = highlightRect.top - 24;
    } else if (canPlaceBelow) {
      x = highlightRect.right - 14;
      y = highlightRect.bottom - 8;
    } else {
      x = highlightRect.left - 24;
      y = highlightRect.top + 12;
    }

    return Offset(x.clamp(8, size.width - 42), y.clamp(8, size.height - 160));
  }

  _TourCardPosition _cardPosition({
    required Size size,
    required MediaQueryData media,
    required Rect highlightRect,
    required AppTourHighlightShape shape,
  }) {
    final bottomPad = media.padding.bottom + 16;
    final topPad = media.padding.top + 16;

    if (shape == AppTourHighlightShape.fullscreen) {
      return _TourCardPosition(bottom: bottomPad);
    }

    final placeTop = highlightRect.center.dy >= (size.height * 0.58);
    if (placeTop) {
      return _TourCardPosition(top: topPad);
    }
    return _TourCardPosition(bottom: bottomPad);
  }

  Widget _messageCard(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '👆 ${widget.hint.title}   (${widget.index + 1}/${widget.total})',
              style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
            ),
            const SizedBox(height: 6),
            Text(
              widget.hint.line,
              style: const TextStyle(fontWeight: FontWeight.w700, height: 1.35),
            ),
            const SizedBox(height: 6),
            CheckboxListTile(
              value: _dontShowAgain,
              dense: true,
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              onChanged: (v) {
                setState(() {
                  _dontShowAgain = v ?? false;
                });
                widget.onDontShowAgainChanged(_dontShowAgain);
              },
              title: Text(
                widget.texts.dontShowAgain,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () =>
                      Navigator.of(context).pop(_TourStepAction.skip),
                  child: Text(widget.texts.skip),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(
                    widget.isLast ? _TourStepAction.done : _TourStepAction.next,
                  ),
                  child: Text(widget.isLast ? widget.texts.done : widget.texts.next),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TourCardPosition {
  const _TourCardPosition({this.top, this.bottom});

  final double? top;
  final double? bottom;
}

class _CoachOverlayPainter extends CustomPainter {
  const _CoachOverlayPainter({required this.highlightRect, required this.shape});

  final Rect highlightRect;
  final AppTourHighlightShape shape;

  @override
  void paint(Canvas canvas, Size size) {
    final overlay = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height));

    final cutoutPath = _shapePath();
    overlay.addPath(cutoutPath, Offset.zero);
    overlay.fillType = PathFillType.evenOdd;

    final ringPaint = Paint()
      ..color = const Color(0xFFF98D28)
      ..style = PaintingStyle.stroke
      ..strokeWidth = shape == AppTourHighlightShape.fullscreen ? 2.5 : 3;
    canvas.drawPath(cutoutPath, ringPaint);

    final bgPaint = Paint()..color = Colors.black.withValues(alpha: 0.62);
    canvas.drawPath(overlay, bgPaint);
  }

  @override
  bool shouldRepaint(covariant _CoachOverlayPainter oldDelegate) {
    return oldDelegate.highlightRect != highlightRect || oldDelegate.shape != shape;
  }

  Path _shapePath() {
    switch (shape) {
      case AppTourHighlightShape.circle:
        return Path()..addOval(highlightRect);
      case AppTourHighlightShape.rectangle:
      case AppTourHighlightShape.fullscreen:
        return Path()..addRect(highlightRect);
      case AppTourHighlightShape.roundedRectangle:
      case AppTourHighlightShape.auto:
        return Path()
          ..addRRect(
            RRect.fromRectAndRadius(highlightRect, const Radius.circular(14)),
          );
    }
  }
}
