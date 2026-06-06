import 'dart:async';

import 'package:flutter/material.dart';

import 'ybs_busy_logo.dart';

enum AppToastType { info, success, error }

/// App-wide branded feedback surface.
///
/// Guidelines:
/// - Prefer `AppToast.show(...)` over raw SnackBars.
/// - Keep messages short (1 sentence).
/// - Use `success` for completed actions, `error` for failures, `info` for hints.
class AppToast {
  static OverlayEntry? _activeEntry;
  static Timer? _activeTimer;

  static void show(
    BuildContext context,
    String message, {
    AppToastType type = AppToastType.info,
    Duration duration = const Duration(seconds: 3),
  }) {
    final trimmed = message.trim();
    if (trimmed.isEmpty) return;

    _activeTimer?.cancel();
    _activeTimer = null;
    _activeEntry?.remove();
    _activeEntry = null;

    final overlay = Overlay.of(context, rootOverlay: true);

    final _ToastStyle style = _styleFor(type);

    final entry = OverlayEntry(
      builder: (ctx) {
        return SafeArea(
          child: IgnorePointer(
            ignoring: true,
            child: Align(
              alignment: Alignment.topCenter,
              child: TweenAnimationBuilder<double>(
                duration: const Duration(milliseconds: 220),
                tween: Tween<double>(begin: 0, end: 1),
                curve: Curves.easeOutCubic,
                builder: (context, value, child) {
                  final dy = (1 - value) * -16;
                  return Transform.translate(
                    offset: Offset(0, dy),
                    child: Opacity(opacity: value, child: child),
                  );
                },
                child: Container(
                  margin: const EdgeInsets.fromLTRB(14, 10, 14, 0),
                  constraints: const BoxConstraints(maxWidth: 560),
                  decoration: BoxDecoration(
                    color: style.bg,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: style.border),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.12),
                        blurRadius: 18,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                    child: Row(
                      children: [
                        Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: style.border),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(9),
                            child: Image.asset(
                              'assets/images/ybs_logo.png',
                              fit: BoxFit.contain,
                              errorBuilder: (_, _, _) => Icon(
                                Icons.school_rounded,
                                color: style.fg,
                                size: 18,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Icon(style.icon, color: style.fg, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            trimmed,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: style.fg,
                              fontWeight: FontWeight.w800,
                              fontSize: 13,
                              height: 1.3,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );

    overlay.insert(entry);
    _activeEntry = entry;

    _activeTimer = Timer(duration, () {
      _activeTimer?.cancel();
      _activeTimer = null;
      _activeEntry?.remove();
      _activeEntry = null;
    });
  }

  static void fromSnackBar(
    BuildContext context,
    SnackBar snackBar, {
    AppToastType? type,
  }) {
    final message = _normalizeMessage(_extractMessage(snackBar.content));
    show(
      context,
      message.isEmpty ? 'Done.' : message,
      type: type ?? _inferTypeFromMessage(message),
      duration: snackBar.duration,
    );
  }

  static _ToastStyle _styleFor(AppToastType type) {
    switch (type) {
      case AppToastType.success:
        return const _ToastStyle(
          bg: Color(0xFFF0FDF4),
          border: Color(0xFFBBF7D0),
          fg: Color(0xFF166534),
          icon: Icons.check_circle_rounded,
        );
      case AppToastType.error:
        return const _ToastStyle(
          bg: Color(0xFFFEF2F2),
          border: Color(0xFFFECACA),
          fg: Color(0xFFB91C1C),
          icon: Icons.error_rounded,
        );
      case AppToastType.info:
        return const _ToastStyle(
          bg: Color(0xFFEEF6FF),
          border: Color(0xFFBFDBFE),
          fg: Color(0xFF1E3A8A),
          icon: Icons.info_rounded,
        );
    }
  }

  static AppToastType _inferTypeFromMessage(String message) {
    final m = message.toLowerCase();
    if (m.contains('error') ||
        m.contains('failed') ||
        m.contains('could not') ||
        m.contains('invalid') ||
        m.contains('forbidden')) {
      return AppToastType.error;
    }

    if (m.contains('saved') ||
        m.contains('success') ||
        m.contains('uploaded') ||
        m.contains('deleted') ||
        m.contains('updated') ||
        m.contains('completed')) {
      return AppToastType.success;
    }

    return AppToastType.info;
  }

  static String _extractMessage(Widget widget) {
    if (widget is Text) {
      final plain = widget.data?.trim() ?? '';
      if (plain.isNotEmpty) return plain;
      return widget.textSpan?.toPlainText().trim() ?? '';
    }

    if (widget is RichText) {
      return widget.text.toPlainText().trim();
    }

    if (widget is Icon) return '';

    if (widget is Row) {
      for (final child in widget.children) {
        final msg = _extractMessage(child);
        if (msg.isNotEmpty) return msg;
      }
      return '';
    }

    if (widget is Column) {
      for (final child in widget.children) {
        final msg = _extractMessage(child);
        if (msg.isNotEmpty) return msg;
      }
      return '';
    }

    if (widget is Padding) {
      return _extractMessage(widget.child ?? const SizedBox.shrink());
    }

    if (widget is Center) {
      return _extractMessage(widget.child ?? const SizedBox.shrink());
    }

    if (widget is Expanded) {
      return _extractMessage(widget.child);
    }

    if (widget is Flexible) {
      return _extractMessage(widget.child);
    }

    if (widget is SizedBox && widget.child != null) {
      return _extractMessage(widget.child!);
    }

    return '';
  }

  static String _normalizeMessage(String raw) {
    var m = raw.trim();
    if (m.isEmpty) return m;

    // Keep toast copy short and professional.
    m = m
        .replaceAll('✅', '')
        .replaceAll('❌', '')
        .replaceAll('🗑️', '')
        .replaceAll('🗑', '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    if (m.isEmpty) return m;

    // Ensure sentence-like ending.
    if (!m.endsWith('.') && !m.endsWith('!') && !m.endsWith('?')) {
      m = '$m.';
    }

    return m;
  }
}

class AppLoading {
  static Future<T> run<T>(
    BuildContext context,
    Future<T> Function() task, {
    String message = 'Please wait...',
    bool isLogout = false,
  }) async {
    final overlay = Overlay.of(context, rootOverlay: true);
    final entry = OverlayEntry(
      builder: (_) => PopScope(
        canPop: false,
        child: Material(
          color: Colors.black.withValues(alpha: 0.18),
          child: Center(
            child: isLogout
                ? _LogoutLoadingDialog(message: message)
                : _AppLoadingDialog(message: message),
          ),
        ),
      ),
    );

    overlay.insert(entry);

    try {
      return await task();
    } finally {
      try {
        entry.remove();
      } catch (_) {}
    }
  }
}

class ProgressDialog {
  static Future<void> run(
    BuildContext context, {
    required String message,
    required int total,
    required Future<void> Function(void Function(int current) reportProgress)
        task,
  }) async {
    final overlay = Overlay.of(context, rootOverlay: true);
    int current = 0;

    final entry = OverlayEntry(
      builder: (_) => PopScope(
        canPop: false,
        child: Material(
          color: Colors.black.withValues(alpha: 0.18),
          child: Center(
            child: _ProgressDialogContent(
              message: message,
              current: current,
              total: total,
            ),
          ),
        ),
      ),
    );

    overlay.insert(entry);

    try {
      await task((value) {
        current = value;
        try {
          entry.markNeedsBuild();
        } catch (_) {}
      });
    } finally {
      try {
        entry.remove();
      } catch (_) {}
    }
  }
}

class _ProgressDialogContent extends StatelessWidget {
  const _ProgressDialogContent({
    required this.message,
    required this.current,
    required this.total,
  });

  final String message;
  final int current;
  final int total;

  @override
  Widget build(BuildContext context) {
    final progress = total > 0 ? (current / total).clamp(0.0, 1.0) : 0.0;

    return Container(
      constraints: const BoxConstraints(maxWidth: 320),
      margin: const EdgeInsets.symmetric(horizontal: 20),
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const YbsBusyLogo(size: 48),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontWeight: FontWeight.w800,
              color: Color(0xFF0F172A),
              height: 1.3,
            ),
          ),
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 10,
              backgroundColor: const Color(0xFFE2E8F0),
              valueColor: const AlwaysStoppedAnimation<Color>(
                Color(0xFF1D4ED8),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '$current of $total',
            style: TextStyle(
              color: Colors.black.withValues(alpha: 0.55),
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

class BrandedInlineLoader extends StatelessWidget {
  const BrandedInlineLoader({super.key, this.message = 'Loading...'});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const YbsBusyLogo(size: 54),
        const SizedBox(height: 10),
        Text(message, style: const TextStyle(fontWeight: FontWeight.w700)),
      ],
    );
  }
}

class _AppLoadingDialog extends StatelessWidget {
  const _AppLoadingDialog({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 320),
      margin: const EdgeInsets.symmetric(horizontal: 20),
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const YbsBusyLogo(size: 58),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontWeight: FontWeight.w800,
              color: Color(0xFF0F172A),
              height: 1.3,
            ),
          ),
        ],
      ),
    );
  }
}

class _LogoutLoadingDialog extends StatefulWidget {
  const _LogoutLoadingDialog({required this.message});

  final String message;

  @override
  State<_LogoutLoadingDialog> createState() => _LogoutLoadingDialogState();
}

class _LogoutLoadingDialogState extends State<_LogoutLoadingDialog>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scale = Tween<double>(
      begin: 0.94,
      end: 1.04,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
    final glow = Tween<double>(
      begin: 0.08,
      end: 0.18,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));

    return Container(
      constraints: const BoxConstraints(maxWidth: 300),
      margin: const EdgeInsets.symmetric(horizontal: 20),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              return Transform.scale(
                scale: scale.value,
                child: Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: const Color(
                          0xFF1D4ED8,
                        ).withValues(alpha: glow.value),
                        blurRadius: 16,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: child,
                ),
              );
            },
            child: ClipOval(
              child: Image.asset(
                'assets/images/ybs_logo.png',
                width: 64,
                height: 64,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const Icon(
                  Icons.school_rounded,
                  size: 38,
                  color: Color(0xFF1E293B),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            widget.message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
              color: Color(0xFF64748B),
              height: 1.25,
            ),
          ),
        ],
      ),
    );
  }
}

class _ToastStyle {
  const _ToastStyle({
    required this.bg,
    required this.border,
    required this.fg,
    required this.icon,
  });

  final Color bg;
  final Color border;
  final Color fg;
  final IconData icon;
}
