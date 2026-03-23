import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LearnerTourHint {
  const LearnerTourHint({
    required this.title,
    required this.line,
    this.targetKey,
  });

  final String title;
  final String line;
  final GlobalKey? targetKey;
}

enum _TourStepAction { next, skip, done }

class LearnerTourGuide {
  static const String _hideAllPref = 'learner_tour_hide_all';
  static const String _quickStartDonePref = 'learner_tour_quick_start_done';
  static const String _seenPrefix = 'learner_tour_seen_';
  static final Set<String> _shownThisSession = <String>{};

  static bool _running = false;

  static void schedule(
    BuildContext context, {
    required String screenId,
    required List<LearnerTourHint> hints,
    bool isQuickStart = false,
  }) {
    if (hints.isEmpty) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      maybeStart(
        context,
        screenId: screenId,
        hints: hints,
        isQuickStart: isQuickStart,
      );
    });
  }

  static Future<void> resetAll() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys();

    await prefs.remove(_hideAllPref);
    await prefs.remove(_quickStartDonePref);
    for (final key in keys) {
      if (key.startsWith(_seenPrefix)) {
        await prefs.remove(key);
      }
    }
    _shownThisSession.clear();
  }

  static Future<bool> shouldShow(
    String screenId, {
    bool isQuickStart = false,
  }) async {
    if (_running) return false;
    if (_shownThisSession.contains(screenId)) return false;

    final prefs = await SharedPreferences.getInstance();
    final hideAll = prefs.getBool(_hideAllPref) ?? false;
    if (hideAll) return false;

    final quickDone = prefs.getBool(_quickStartDonePref) ?? false;
    if (!isQuickStart && !quickDone) return false;
    if (isQuickStart && quickDone) return false;

    final seenKey = '$_seenPrefix$screenId';
    final seenBefore = prefs.getBool(seenKey) ?? false;
    return !seenBefore;
  }

  static Future<void> startNow(
    BuildContext context, {
    required String screenId,
    required List<LearnerTourHint> hints,
    bool isQuickStart = false,
  }) {
    return maybeStart(
      context,
      screenId: screenId,
      hints: hints,
      isQuickStart: isQuickStart,
      force: true,
    );
  }

  static Future<void> maybeStart(
    BuildContext context, {
    required String screenId,
    required List<LearnerTourHint> hints,
    bool isQuickStart = false,
    bool force = false,
  }) async {
    if (!context.mounted) return;
    if (hints.isEmpty) return;
    if (_running) return;
    if (!force && _shownThisSession.contains(screenId)) return;

    final prefs = await SharedPreferences.getInstance();
    if (!context.mounted) return;
    final hideAll = prefs.getBool(_hideAllPref) ?? false;
    if (hideAll && !force) return;

    final quickDone = prefs.getBool(_quickStartDonePref) ?? false;
    if (!isQuickStart && !quickDone && !force) return;

    if (isQuickStart && quickDone && !force) return;

    final seenKey = '$_seenPrefix$screenId';
    final seenBefore = prefs.getBool(seenKey) ?? false;
    if (!force && seenBefore) return;

    _shownThisSession.add(screenId);
    _running = true;

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
          return _LearnerTourStepDialog(
            hint: current,
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

    await prefs.setBool(seenKey, true);
    if (isQuickStart) {
      await prefs.setBool(_quickStartDonePref, true);
    }

    if (dontShowAgain) {
      await prefs.setBool(_hideAllPref, true);
    }

    _running = false;
  }
}

class _LearnerTourStepDialog extends StatefulWidget {
  const _LearnerTourStepDialog({
    required this.hint,
    required this.index,
    required this.total,
    required this.isLast,
    required this.initialDontShowAgain,
    required this.onDontShowAgainChanged,
  });

  final LearnerTourHint hint;
  final int index;
  final int total;
  final bool isLast;
  final bool initialDontShowAgain;
  final ValueChanged<bool> onDontShowAgainChanged;

  @override
  State<_LearnerTourStepDialog> createState() => _LearnerTourStepDialogState();
}

class _LearnerTourStepDialogState extends State<_LearnerTourStepDialog> {
  late bool _dontShowAgain;

  @override
  void initState() {
    super.initState();
    _dontShowAgain = widget.initialDontShowAgain;
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final size = media.size;
    final targetRect = _targetRect(widget.hint.targetKey);
    final cardBottom = media.padding.bottom + 16;

    final fingerPos = _fingerPosition(size: size, targetRect: targetRect);

    return Material(
      color: Colors.transparent,
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _CoachOverlayPainter(targetRect: targetRect),
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
            bottom: cardBottom,
            child: _messageCard(context),
          ),
        ],
      ),
    );
  }

  Rect? _targetRect(GlobalKey? key) {
    final ctx = key?.currentContext;
    if (ctx == null) return null;
    final ro = ctx.findRenderObject();
    if (ro is! RenderBox || !ro.hasSize) return null;

    final origin = ro.localToGlobal(Offset.zero);
    return origin & ro.size;
  }

  Offset? _fingerPosition({required Size size, required Rect? targetRect}) {
    if (targetRect == null) return null;

    final x = targetRect.right - 12;
    final y = targetRect.top - 24;
    return Offset(x.clamp(8, size.width - 42), y.clamp(8, size.height - 160));
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
              textDirection: TextDirection.rtl,
              style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
            ),
            const SizedBox(height: 6),
            Text(
              widget.hint.line,
              textDirection: TextDirection.rtl,
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
              title: const Text(
                'لا تظهر هذه التعليمات مرة اخرى',
                textDirection: TextDirection.rtl,
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () =>
                      Navigator.of(context).pop(_TourStepAction.skip),
                  child: const Text('تخطي'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(
                    widget.isLast ? _TourStepAction.done : _TourStepAction.next,
                  ),
                  child: Text(widget.isLast ? 'تم' : 'التالي'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CoachOverlayPainter extends CustomPainter {
  const _CoachOverlayPainter({required this.targetRect});

  final Rect? targetRect;

  @override
  void paint(Canvas canvas, Size size) {
    final overlay = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    if (targetRect != null) {
      final diameter = math.max(targetRect!.width, targetRect!.height) + 20;
      final circleRect = Rect.fromCircle(
        center: targetRect!.center,
        radius: diameter / 2,
      );
      overlay.addOval(circleRect);
      overlay.fillType = PathFillType.evenOdd;

      final ringPaint = Paint()
        ..color = const Color(0xFFF98D28)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3;
      canvas.drawOval(circleRect, ringPaint);
    }

    final bgPaint = Paint()..color = Colors.black.withValues(alpha: 0.62);
    canvas.drawPath(overlay, bgPaint);
  }

  @override
  bool shouldRepaint(covariant _CoachOverlayPainter oldDelegate) {
    return oldDelegate.targetRect != targetRect;
  }
}
