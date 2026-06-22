import 'package:flutter/material.dart';

import 'app_theme.dart';

enum LearnerNoticeTone { info, success, warning, error }

bool _learnerNoticeOpen = false;

Future<void> showLearnerNoticePopup(
  BuildContext context, {
  required String message,
  LearnerNoticeTone tone = LearnerNoticeTone.info,
  String? englishTitle,
  String? arabicTitle,
  String? arabicSummary,
  IconData? icon,
}) async {
  final clean = message.trim();
  if (clean.isEmpty || _learnerNoticeOpen || !context.mounted) return;

  final style = _styleFor(
    tone: tone,
    englishTitle: englishTitle,
    arabicTitle: arabicTitle,
    arabicSummary: arabicSummary,
    icon: icon,
  );
  final palette = appThemeController.palette;

  _learnerNoticeOpen = true;
  try {
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) {
        return Dialog(
          elevation: 16,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 18,
            vertical: 24,
          ),
          backgroundColor: Colors.transparent,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(26),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [palette.cardBg, style.softColor],
                ),
                border: Border.all(color: style.color.withValues(alpha: 0.22)),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x2E000000),
                    blurRadius: 24,
                    offset: Offset(0, 14),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(26),
                child: Stack(
                  children: [
                    Positioned(
                      right: -28,
                      top: -30,
                      child: Container(
                        width: 116,
                        height: 116,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: style.color.withValues(alpha: 0.09),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 58,
                            height: 58,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: style.color.withValues(alpha: 0.13),
                              border: Border.all(
                                color: style.color.withValues(alpha: 0.28),
                              ),
                            ),
                            child: Icon(
                              style.icon,
                              color: style.color,
                              size: 29,
                            ),
                          ),
                          const SizedBox(height: 14),
                          Text(
                            style.arabicTitle,
                            textDirection: TextDirection.rtl,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: palette.text,
                              fontSize: 21,
                              fontWeight: FontWeight.w900,
                              height: 1.2,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            style.englishTitle,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: style.color,
                              fontSize: 16,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 14),
                          Container(
                            width: double.infinity,
                            constraints: const BoxConstraints(maxHeight: 210),
                            padding: const EdgeInsets.fromLTRB(14, 13, 14, 12),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.74),
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(
                                color: style.color.withValues(alpha: 0.14),
                              ),
                            ),
                            child: SingleChildScrollView(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Text(
                                    style.arabicSummary,
                                    textDirection: TextDirection.rtl,
                                    textAlign: TextAlign.right,
                                    style: TextStyle(
                                      color: palette.text,
                                      fontWeight: FontWeight.w800,
                                      height: 1.5,
                                      fontSize: 14.5,
                                    ),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 10,
                                    ),
                                    child: Divider(
                                      height: 1,
                                      color: palette.border.withValues(
                                        alpha: 0.55,
                                      ),
                                    ),
                                  ),
                                  Text(
                                    clean,
                                    textAlign: TextAlign.left,
                                    style: TextStyle(
                                      color: palette.text.withValues(
                                        alpha: 0.84,
                                      ),
                                      fontWeight: FontWeight.w700,
                                      height: 1.42,
                                      fontSize: 14,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton(
                              style: FilledButton.styleFrom(
                                backgroundColor: style.color,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 13,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(999),
                                ),
                              ),
                              onPressed: () =>
                                  Navigator.of(dialogContext).pop(),
                              child: const Text(
                                'حسنًا / OK',
                                style: TextStyle(fontWeight: FontWeight.w900),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  } finally {
    _learnerNoticeOpen = false;
  }
}

LearnerNoticeTone learnerNoticeToneForMessage(String message) {
  final lower = message.toLowerCase();
  if (lower.contains('success') ||
      lower.contains('submitted') ||
      lower.contains('updated') ||
      lower.contains('downloaded') ||
      lower.contains('ready') ||
      lower.contains('completed') ||
      lower.contains('deleted') ||
      lower.contains('posted') ||
      lower.contains('reported')) {
    return LearnerNoticeTone.success;
  }
  if (lower.contains('failed') ||
      lower.contains('could not') ||
      lower.contains('invalid') ||
      lower.contains('error') ||
      lower.contains('incorrect') ||
      lower.contains('denied') ||
      lower.contains('not logged in')) {
    return LearnerNoticeTone.error;
  }
  if (lower.contains('expired') ||
      lower.contains('not available') ||
      lower.contains('need internet') ||
      lower.contains('needs internet') ||
      lower.contains('please') ||
      lower.contains('only enrolled') ||
      lower.contains('too long') ||
      lower.contains('limit')) {
    return LearnerNoticeTone.warning;
  }
  return LearnerNoticeTone.info;
}

_LearnerNoticeStyle _styleFor({
  required LearnerNoticeTone tone,
  String? englishTitle,
  String? arabicTitle,
  String? arabicSummary,
  IconData? icon,
}) {
  switch (tone) {
    case LearnerNoticeTone.success:
      return _LearnerNoticeStyle(
        englishTitle: englishTitle ?? 'Done Successfully',
        arabicTitle: arabicTitle ?? 'تم بنجاح',
        arabicSummary:
            arabicSummary ?? 'تم تنفيذ العملية بنجاح. يمكنك المتابعة الآن.',
        color: const Color(0xFF168A4A),
        softColor: const Color(0xFFEFFAF3),
        icon: icon ?? Icons.check_circle_rounded,
      );
    case LearnerNoticeTone.warning:
      return _LearnerNoticeStyle(
        englishTitle: englishTitle ?? 'Please Note',
        arabicTitle: arabicTitle ?? 'يرجى الانتباه',
        arabicSummary:
            arabicSummary ?? 'يرجى الاطلاع على الرسالة التالية قبل المتابعة.',
        color: const Color(0xFFC27A12),
        softColor: const Color(0xFFFFF7E8),
        icon: icon ?? Icons.info_rounded,
      );
    case LearnerNoticeTone.error:
      return _LearnerNoticeStyle(
        englishTitle: englishTitle ?? 'Action Needed',
        arabicTitle: arabicTitle ?? 'يلزم الانتباه',
        arabicSummary:
            arabicSummary ??
            'تعذر إكمال الطلب الآن. يرجى مراجعة الرسالة والمحاولة مرة أخرى.',
        color: const Color(0xFFB42318),
        softColor: const Color(0xFFFFF1F1),
        icon: icon ?? Icons.error_rounded,
      );
    case LearnerNoticeTone.info:
      return _LearnerNoticeStyle(
        englishTitle: englishTitle ?? 'Notice',
        arabicTitle: arabicTitle ?? 'تنبيه',
        arabicSummary:
            arabicSummary ?? 'يرجى الاطلاع على الرسالة التالية قبل المتابعة.',
        color: const Color(0xFF0E7C86),
        softColor: const Color(0xFFEAF7FA),
        icon: icon ?? Icons.notifications_active_rounded,
      );
  }
}

class _LearnerNoticeStyle {
  const _LearnerNoticeStyle({
    required this.englishTitle,
    required this.arabicTitle,
    required this.arabicSummary,
    required this.color,
    required this.softColor,
    required this.icon,
  });

  final String englishTitle;
  final String arabicTitle;
  final String arabicSummary;
  final Color color;
  final Color softColor;
  final IconData icon;
}
