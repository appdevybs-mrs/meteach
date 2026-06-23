import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:flutter_facebook_auth/flutter_facebook_auth.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'enroll_screen.dart';
import 'course_reviews_screen.dart';
import 'services/fcm_service.dart';
import 'services/app_launch_action_service.dart';
import 'services/backend_api.dart';
import 'services/course_feedback_service.dart';
import 'services/push_dispatch_service.dart';
import 'services/recorded_progress_sync_service.dart';
import 'firebase_options.dart';
import 'learner/learner_games_screen.dart';
import 'learner/learner_stories_screen.dart';
import 'widgets/teacher_media_sheet.dart';
import 'widgets/enrollment_success_dialog.dart';
import 'shared/app_theme.dart';
import 'shared/app_globals.dart';
import 'shared/app_feedback.dart';
import 'shared/app_connectivity.dart';
import 'shared/course_join_rules.dart';
import 'shared/human_error.dart';
import 'shared/profile_avatar.dart';
import 'shared/ybs_busy_logo.dart';
import 'shared/icon_theme.dart';
import 'shared/app_flavor.dart';
import 'auth/auth_gate.dart';
import 'verify_certificate_screen.dart';
import 'package:video_player/video_player.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

part 'home/home_shell.part.dart';
part 'home/login.part.dart';

String _formatCompactCountdown(int totalSeconds) {
  final total = totalSeconds.clamp(0, 864000);
  final days = total ~/ 86400;
  final hours = (total % 86400) ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final seconds = total % 60;

  if (days > 0) return '${days}d:${hours}h:${minutes}m';
  if (hours > 0) return '${hours}h:${minutes}m';
  if (minutes > 0) return '${minutes}m:${seconds}s';
  return '${seconds}s';
}

Future<void> main() async {
  await runZonedGuarded<Future<void>>(
    () {
      WidgetsFlutterBinding.ensureInitialized();

      return _bootstrapApp();
    },
    (error, stack) {
      FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
      debugPrint('Uncaught zone error: $error\n$stack');
    },
  );
}

Future<void> _bootstrapApp() async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    FirebaseCrashlytics.instance.recordFlutterFatalError(details);
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
    debugPrint('Uncaught platform error: $error\n$stack');
    return true;
  };

  ErrorWidget.builder = (FlutterErrorDetails details) {
    final exception = details.exceptionAsString();
    return Material(
      color: const Color(0xFFFDF2F2),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFFFECACA)),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: SelectableText(
                  'Unexpected UI error.\n\n$exception',
                  style: const TextStyle(
                    color: Color(0xFF7F1D1D),
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  };

  runApp(const YourBridgeSchoolApp());

  WidgetsBinding.instance.addPostFrameCallback((_) {
    AppLaunchActionService.instance.init();
    if (!kIsWeb) {
      unawaited(AppConnectivity.instance.start());
    }
    unawaited(RecordedProgressSyncService.instance.start());
    unawaited(FCMService.I.init());
  });
}

class Brand {
  static const primaryBlue = Color(0xFF1A2B48);
  static const actionOrange = Color(0xFFF98D28);
  static const accentCyan = Color(0xFF00D4FF);
  static const mainText = Color(0xFF2D2D2D);
  static const appBg = Color(0xFFF4F7F9);
  static const uiBorder = Color(0xFFD1D9E0);
}

class YourBridgeSchoolApp extends StatelessWidget {
  const YourBridgeSchoolApp({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: appThemeController,
      builder: (context, _) {
        return MaterialApp(
          navigatorKey: appNavigatorKey,
          scaffoldMessengerKey: messengerKey,
          debugShowCheckedModeBanner: false,
          theme: appThemeController.themeData.copyWith(
            snackBarTheme: const SnackBarThemeData(
              behavior: SnackBarBehavior.floating,
              elevation: 8,
              backgroundColor: Color(0xFF0F172A),
              contentTextStyle: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.all(Radius.circular(14)),
              ),
            ),
          ),
          home: AppStartupGate(
            child: ForceUpdateGate(
              child: const AuthGate(signedOutHome: HomeShell()),
            ),
          ),
        );
      },
    );
  }
}

class AppStartupGate extends StatefulWidget {
  const AppStartupGate({super.key, required this.child});

  final Widget child;

  @override
  State<AppStartupGate> createState() => _AppStartupGateState();
}

class _AppStartupGateState extends State<AppStartupGate> {
  double _progress = 0;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    Future<void> step(Future<void> Function() fn, double progress) async {
      await fn();
      if (!mounted) return;
      setState(() => _progress = progress);
    }

    await step(
      () async => Future<void>.delayed(const Duration(milliseconds: 120)),
      0.2,
    );
    await step(() async => appThemeController.loadSavedTheme(), 0.45);
    await step(() async {
      await PackageInfo.fromPlatform();
    }, 0.7);
    await step(
      () async => Future<void>.delayed(const Duration(milliseconds: 220)),
      0.9,
    );
    await step(
      () async => Future<void>.delayed(const Duration(milliseconds: 180)),
      1.0,
    );

    if (!mounted) return;
    setState(() => _ready = true);
  }

  @override
  Widget build(BuildContext context) {
    if (_ready) return widget.child;
    return _ProgressiveLogoSplash(progress: _progress);
  }
}

class _ProgressiveLogoSplash extends StatelessWidget {
  const _ProgressiveLogoSplash({required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context) {
    final p = progress.clamp(0.0, 1.0).toDouble();
    return Scaffold(
      backgroundColor: Brand.appBg,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 26),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 184,
                  height: 184,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(color: Brand.uiBorder),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.08),
                        blurRadius: 24,
                        offset: const Offset(0, 12),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(26),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Opacity(
                          opacity: 0.12,
                          child: Image.asset(
                            'assets/images/ybs_logo.png',
                            fit: BoxFit.contain,
                          ),
                        ),
                        ClipRect(
                          child: Align(
                            alignment: Alignment.topCenter,
                            heightFactor: p,
                            child: Image.asset(
                              'assets/images/ybs_logo.png',
                              fit: BoxFit.contain,
                              errorBuilder: (_, _, _) => const Icon(
                                Icons.school_rounded,
                                size: 78,
                                color: Brand.primaryBlue,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  'Preparing your learning space...',
                  style: TextStyle(
                    color: Brand.primaryBlue,
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    minHeight: 8,
                    value: p,
                    backgroundColor: Brand.uiBorder,
                    color: Brand.actionOrange,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class SoftBackground extends StatelessWidget {
  final Widget child;
  const SoftBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Container(decoration: const BoxDecoration(color: Brand.appBg)),
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Brand.appBg,
                Brand.appBg.withValues(alpha: 0.85),
                Colors.white.withValues(alpha: 0.55),
              ],
            ),
          ),
        ),
        Positioned.fill(
          child: IgnorePointer(
            child: Opacity(
              opacity: 0.040,
              child: Center(
                child: FractionallySizedBox(
                  widthFactor: 0.72,
                  child: Image.asset(
                    'assets/images/ybs_logo.png',
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => const Icon(
                      Icons.school_rounded,
                      size: 160,
                      color: Brand.uiBorder,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        child,
      ],
    );
  }
}

class SimpleTopBar extends StatelessWidget {
  final String title;
  final Widget? right;

  const SimpleTopBar({super.key, required this.title, this.right});

  static const List<String> _companyNodeCandidates = [
    'appConfig/Company info',
    'appConfig/companyInfo',
    'company',
    'companyProfile',
    'appConfig/company',
    'app/company',
  ];

  static String _pickString(Map<String, dynamic> m, List<String> keys) {
    for (final key in keys) {
      final v = m[key];
      final s = (v ?? '').toString().trim();
      if (s.isNotEmpty) return s;
    }
    return '';
  }

  static _CompanyInfo? _parseCompanyInfo(dynamic value) {
    if (value is! Map) return null;
    final m = value.map((k, v) => MapEntry(k.toString(), v));

    final info = _CompanyInfo(
      fullName: _pickString(m, [
        'companyFullName',
        'company full name',
        'company_full_name',
        'fullName',
        'name',
        'company_name',
      ]),
      phone: _pickString(m, [
        'companyPhone',
        'company phone',
        'company_phone',
        'phone',
      ]),
      email: _pickString(m, [
        'companyEmail',
        'company email',
        'company_email',
        'email',
      ]),
      accreditationNumber: _pickString(m, [
        'companyAccreditationNumber',
        'company accreditation number',
        'company_accreditation_number',
        'accreditationNumber',
        'accreditation_number',
      ]),
      address: _pickString(m, [
        'companyAddress',
        'company address',
        'company_address',
        'address',
      ]),
    );

    if (info.fullName.isEmpty &&
        info.phone.isEmpty &&
        info.email.isEmpty &&
        info.accreditationNumber.isEmpty &&
        info.address.isEmpty) {
      return null;
    }
    return info;
  }

  static Future<_CompanyInfo?> _loadCompanyInfo() async {
    final db = FirebaseDatabase.instance;
    for (final path in _companyNodeCandidates) {
      try {
        final snap = await db.ref(path).get();
        final parsed = _parseCompanyInfo(snap.value);
        if (parsed != null) return parsed;
      } catch (_) {}
    }
    return null;
  }

  static Future<void> _openMapForAddress(
    BuildContext context,
    String address,
  ) async {
    final query = Uri.encodeComponent(address.trim());
    final uri = Uri.parse(
      'https://www.google.com/maps/search/?api=1&query=$query',
    );
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      AppToast.show(
        context,
        'Could not open Google Maps.',
        type: AppToastType.error,
      );
    }
  }

  static Future<void> _openWhatsAppForPhone(
    BuildContext context,
    String phone,
  ) async {
    final trimmed = phone.trim();
    if (trimmed.isEmpty) return;

    final normalized = trimmed.replaceAll(RegExp(r'[^0-9+]'), '');
    final waNumber = normalized.startsWith('+')
        ? normalized.substring(1)
        : normalized;

    if (waNumber.isEmpty) return;

    final uri = Uri.parse('https://wa.me/$waNumber');
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      AppToast.show(
        context,
        'Could not open WhatsApp.',
        type: AppToastType.error,
      );
    }
  }

  static Future<void> _showCompanyPopup(BuildContext context) async {
    final info = await _loadCompanyInfo();
    if (!context.mounted) return;

    if (info == null) {
      AppToast.show(
        context,
        'Company details are not available yet.',
        type: AppToastType.info,
      );
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
        contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
        title: Text(info.fullName.isEmpty ? 'Company Details' : info.fullName),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 84,
                  height: 84,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: Brand.uiBorder),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.08),
                        blurRadius: 14,
                        offset: const Offset(0, 7),
                      ),
                    ],
                  ),
                  child: Image.asset(
                    'assets/images/ybs_logo.png',
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => const Icon(
                      Icons.school_rounded,
                      color: Brand.primaryBlue,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              if (info.phone.isNotEmpty)
                InkWell(
                  onTap: () => _openWhatsAppForPhone(ctx, info.phone),
                  child: Text(
                    'Phone (WhatsApp): ${info.phone}',
                    style: const TextStyle(
                      color: Brand.primaryBlue,
                      decoration: TextDecoration.underline,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              if (info.email.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text('Email: ${info.email}'),
              ],
              if (info.accreditationNumber.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text('Accreditation #: ${info.accreditationNumber}'),
              ],
              if (info.address.isNotEmpty) ...[
                const SizedBox(height: 10),
                InkWell(
                  onTap: () => _openMapForAddress(ctx, info.address),
                  child: Text(
                    'Address: ${info.address}',
                    style: const TextStyle(
                      color: Brand.primaryBlue,
                      decoration: TextDecoration.underline,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
      child: Row(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => _showCompanyPopup(context),
            child: Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.94),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Brand.uiBorder),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.04),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              padding: const EdgeInsets.all(6),
              child: Image.asset(
                'assets/images/ybs_logo.png',
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) =>
                    const Icon(Icons.school_rounded, color: Brand.primaryBlue),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w900,
                color: cs.onSurface,
              ),
            ),
          ),
          if (right != null) ...[const SizedBox(width: 8), right!],
        ],
      ),
    );
  }
}

class CardShell extends StatelessWidget {
  final Widget child;
  const CardShell({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: Colors.white.withValues(alpha: 0.92),
        border: Border.all(color: cs.outline.withValues(alpha: 0.85)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 28,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _CompanyInfo {
  const _CompanyInfo({
    required this.fullName,
    required this.phone,
    required this.email,
    required this.accreditationNumber,
    required this.address,
  });

  final String fullName;
  final String phone;
  final String email;
  final String accreditationNumber;
  final String address;
}

class AssistantHome extends StatelessWidget {
  const AssistantHome({super.key});

  @override
  Widget build(BuildContext context) {
    return SoftBackground(
      child: Column(
        children: [
          const SimpleTopBar(title: 'Your Bridge School'),
          Expanded(
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 980),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _FeatureCardsRow(),
                      const SizedBox(height: 22),
                      const _SectionHeader(
                        title: 'Courses',
                        subtitle: 'Browse all available courses here.',
                      ),
                      const SizedBox(height: 10),
                      const _CoursesByCategory(),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FeatureCardsRow extends StatelessWidget {
  const _FeatureCardsRow();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const spacing = 8.0;
        final narrow = constraints.maxWidth < 480;

        Widget card(Widget w) => SizedBox(width: narrow ? null : 100, child: w);

        final items = <Widget>[
          _FeatureCard(
            icon: MainIcons.premium,
            label: 'Exam',
            color: Brand.actionOrange,
            onTap: () => _openPlayStore(context),
          ),
          _FeatureCard(
            icon: MainIcons.shield,
            label: 'Certificate',
            color: Brand.primaryBlue,
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const VerifyCertificateScreen(),
                ),
              );
            },
          ),
          const _JoinOnlineCircleEntryButton(),
          _FeatureCard(
            icon: Icons.work_outline_rounded,
            label: 'Jobs',
            color: const Color(0xFF5A6AE6),
            onTap: () {
              Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const JobsHome()));
            },
          ),
        ];

        if (!narrow) {
          return SizedBox(
            height: 88,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                card(items[0]),
                SizedBox(width: spacing),
                card(items[1]),
                SizedBox(width: spacing),
                card(items[2]),
                SizedBox(width: spacing),
                card(items[3]),
              ],
            ),
          );
        }

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 88,
              child: Row(
                children: [
                  Expanded(child: items[0]),
                  SizedBox(width: spacing),
                  Expanded(child: items[1]),
                ],
              ),
            ),
            SizedBox(height: spacing),
            SizedBox(
              height: 88,
              child: Row(
                children: [
                  Expanded(child: items[2]),
                  SizedBox(width: spacing),
                  Expanded(child: items[3]),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  void _openPlayStore(BuildContext context) {
    final marketUrl = Uri.parse(
      'market://details?id=com.appdevybs.mycertenglish',
    );
    final webPlayStoreUrl = Uri.parse(
      'https://play.google.com/store/apps/details?id=com.appdevybs.mycertenglish&pcampaignid=web_share',
    );
    launchUrl(marketUrl, mode: LaunchMode.externalApplication).then((ok) {
      if (ok) return;
      launchUrl(webPlayStoreUrl, mode: LaunchMode.externalApplication).then((
        ok,
      ) {
        if (!context.mounted) return;
        if (!ok) {
          AppToast.show(
            context,
            'Could not open Play Store',
            type: AppToastType.error,
          );
        }
      });
    });
  }
}

class _FeatureCard extends StatelessWidget {
  const _FeatureCard({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Brand.uiBorder),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: color, size: 28),
              const SizedBox(height: 6),
              Text(
                label,
                style: TextStyle(
                  color: Brand.primaryBlue,
                  fontWeight: FontWeight.w800,
                  fontSize: 12,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w900,
                  color: Brand.primaryBlue,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Brand.mainText.withValues(alpha: 0.72),
                  fontWeight: FontWeight.w600,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _JoinOnlineCircleEntryButton extends StatefulWidget {
  const _JoinOnlineCircleEntryButton();

  @override
  State<_JoinOnlineCircleEntryButton> createState() =>
      _JoinOnlineCircleEntryButtonState();
}

class _JoinOnlineCircleEntryButtonState
    extends State<_JoinOnlineCircleEntryButton> {
  static const String circlesPath = 'circle';
  late final PageController _pageController;
  List<_OnlineCircle> _prefetchedOpenCircles = const [];
  bool _prefetching = true;
  int _activeIndex = 0;
  String _openCirclesSignature = '';
  final Map<String, String> _teacherPhotoCache = <String, String>{};
  final Map<String, Future<String>> _teacherPhotoLoads =
      <String, Future<String>>{};
  final Map<String, List<String>> _teacherPhotosCache =
      <String, List<String>>{};
  final Map<String, Future<List<String>>> _teacherPhotosLoads =
      <String, Future<List<String>>>{};
  String _openCircleTeacherPhotosSignature = '';
  List<String> _openCircleTeacherPhotosCache = const <String>[];
  Future<List<String>>? _openCircleTeacherPhotosLoad;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(viewportFraction: 0.86);
    _prefetchCircles();
  }

  DatabaseReference get _circlesRef =>
      FirebaseDatabase.instance.ref(circlesPath);

  static int _toInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  static String _safe(dynamic v) => (v ?? '').toString().trim();

  static bool _isSafeUid(String uid) {
    final v = uid.trim();
    if (v.length < 8) return false;
    if (v.contains('/') ||
        v.contains('.') ||
        v.contains('#') ||
        v.contains(r'$') ||
        v.contains('[') ||
        v.contains(']')) {
      return false;
    }
    return true;
  }

  String _resolvePhotoFromProfile(dynamic raw) {
    if (raw is! Map) return '';
    return ProfileAvatar.resolvePhotoFromMap(Map<dynamic, dynamic>.from(raw));
  }

  List<String> _resolvePhotosFromProfile(dynamic raw) {
    if (raw is! Map) return const <String>[];
    final profile = Map<dynamic, dynamic>.from(raw);
    final out = <String>[];
    final seen = <String>{};

    void add(dynamic value) {
      final url = value.toString().trim();
      if (url.isEmpty || !seen.add(url)) return;
      out.add(url);
    }

    add(profile['profile_photo']);

    final rawPhotos = profile['profile_photos'];
    if (rawPhotos is List) {
      for (final item in rawPhotos) {
        add(item);
      }
    } else if (rawPhotos is Map) {
      final entries = rawPhotos.entries.toList()
        ..sort((a, b) {
          final ai = int.tryParse(a.key.toString()) ?? 999999;
          final bi = int.tryParse(b.key.toString()) ?? 999999;
          return ai.compareTo(bi);
        });
      for (final entry in entries) {
        add(entry.value);
      }
    }

    return out;
  }

  Future<String> _resolveTeacherPhoto(
    String teacherUid, {
    String fallbackUrl = '',
  }) {
    final uid = teacherUid.trim();
    final fallback = fallbackUrl.trim();
    if (!_isSafeUid(uid)) {
      return Future<String>.value(fallback);
    }
    if (_teacherPhotoCache.containsKey(uid)) {
      return Future<String>.value(_teacherPhotoCache[uid] ?? fallback);
    }
    final inFlight = _teacherPhotoLoads[uid];
    if (inFlight != null) return inFlight;

    final future = () async {
      try {
        final userSnap = await FirebaseDatabase.instance
            .ref('users/$uid')
            .get();
        final fromUser = _resolvePhotoFromProfile(userSnap.value);
        if (fromUser.isNotEmpty) {
          _teacherPhotoCache[uid] = fromUser;
          return fromUser;
        }

        final websiteSnap = await FirebaseDatabase.instance
            .ref('website/teachers/$uid/profile')
            .get();
        final fromWebsite = _resolvePhotoFromProfile(websiteSnap.value);
        final resolved = fromWebsite.isNotEmpty ? fromWebsite : fallback;
        _teacherPhotoCache[uid] = resolved;
        return resolved;
      } catch (_) {
        _teacherPhotoCache[uid] = fallback;
        return fallback;
      } finally {
        _teacherPhotoLoads.remove(uid);
      }
    }();

    _teacherPhotoLoads[uid] = future;
    return future;
  }

  Future<List<String>> _resolveTeacherPhotos(
    String teacherUid, {
    String fallbackUrl = '',
  }) {
    final uid = teacherUid.trim();
    final fallback = fallbackUrl.trim();
    if (!_isSafeUid(uid)) {
      return Future<List<String>>.value(
        fallback.isEmpty ? const <String>[] : <String>[fallback],
      );
    }
    final cached = _teacherPhotosCache[uid];
    if (cached != null && cached.isNotEmpty) {
      return Future<List<String>>.value(cached);
    }
    final inFlight = _teacherPhotosLoads[uid];
    if (inFlight != null) return inFlight;

    final future = () async {
      try {
        final userSnap = await FirebaseDatabase.instance
            .ref('users/$uid')
            .get();
        final fromUser = _resolvePhotosFromProfile(userSnap.value);
        if (fromUser.isNotEmpty) {
          _teacherPhotosCache[uid] = fromUser;
          _teacherPhotoCache[uid] = fromUser.first;
          return fromUser;
        }

        final websiteSnap = await FirebaseDatabase.instance
            .ref('website/teachers/$uid/profile')
            .get();
        final fromWebsite = _resolvePhotosFromProfile(websiteSnap.value);
        final resolved = fromWebsite.isNotEmpty
            ? fromWebsite
            : (fallback.isEmpty ? const <String>[] : <String>[fallback]);
        _teacherPhotosCache[uid] = resolved;
        if (resolved.isNotEmpty) _teacherPhotoCache[uid] = resolved.first;
        return resolved;
      } catch (_) {
        final resolved = fallback.isEmpty
            ? const <String>[]
            : <String>[fallback];
        _teacherPhotosCache[uid] = resolved;
        if (resolved.isNotEmpty) _teacherPhotoCache[uid] = resolved.first;
        return resolved;
      } finally {
        _teacherPhotosLoads.remove(uid);
      }
    }();

    _teacherPhotosLoads[uid] = future;
    return future;
  }

  Future<List<String>> _resolveOpenCircleTeacherPhotos(
    List<_OnlineCircle> circles,
  ) {
    final signature =
        circles
            .map(
              (c) => '${c.teacherUid.trim()}_${c.teacherProfilePhoto.trim()}',
            )
            .where((v) => v.isNotEmpty && v != '_')
            .toSet()
            .toList()
          ..sort();
    final key = signature.join('|');

    if (key.isEmpty) {
      _openCircleTeacherPhotosSignature = '';
      _openCircleTeacherPhotosCache = const <String>[];
      _openCircleTeacherPhotosLoad = null;
      return Future<List<String>>.value(const <String>[]);
    }

    if (_openCircleTeacherPhotosSignature == key &&
        _openCircleTeacherPhotosCache.isNotEmpty) {
      return Future<List<String>>.value(_openCircleTeacherPhotosCache);
    }

    final inFlight = _openCircleTeacherPhotosLoad;
    if (_openCircleTeacherPhotosSignature == key && inFlight != null) {
      return inFlight;
    }

    final seenTeachers = <String>{};
    final futures = <Future<List<String>>>[];
    for (final circle in circles) {
      final uid = circle.teacherUid.trim();
      if (!_isSafeUid(uid) || !seenTeachers.add(uid)) continue;
      futures.add(
        _resolveTeacherPhotos(uid, fallbackUrl: circle.teacherProfilePhoto),
      );
    }

    _openCircleTeacherPhotosSignature = key;
    final future = Future.wait(futures)
        .then((photoLists) {
          final seenUrls = <String>{};
          final photos = photoLists
              .expand((urls) => urls)
              .map((url) => url.trim())
              .where((url) => url.isNotEmpty && seenUrls.add(url))
              .toList(growable: false);
          _openCircleTeacherPhotosCache = photos;
          return photos;
        })
        .whenComplete(() {
          if (_openCircleTeacherPhotosSignature == key) {
            _openCircleTeacherPhotosLoad = null;
          }
        });
    _openCircleTeacherPhotosLoad = future;
    return future;
  }

  Widget _buildOpenCircleTeacherIcon({
    required List<_OnlineCircle> circles,
    required double size,
    required BorderRadius borderRadius,
    required Color backgroundColor,
    required IconData fallbackIcon,
    required Color fallbackIconColor,
    double fallbackIconSize = 24,
  }) {
    return FutureBuilder<List<String>>(
      future: _resolveOpenCircleTeacherPhotos(circles),
      initialData: _openCircleTeacherPhotosCache,
      builder: (context, snapshot) {
        final photos = snapshot.data ?? const <String>[];
        return _RotatingTeacherPhotoIcon(
          photoUrls: photos,
          size: size,
          borderRadius: borderRadius,
          backgroundColor: backgroundColor,
          fallbackIcon: fallbackIcon,
          fallbackIconColor: fallbackIconColor,
          fallbackIconSize: fallbackIconSize,
        );
      },
    );
  }

  Widget _liveTeacherAvatar({
    required _OnlineCircle circle,
    required String teacherName,
    required double radius,
    required Color fallbackBg,
    required Color fallbackFg,
    Color? borderColor,
  }) {
    return FutureBuilder<String>(
      future: _resolveTeacherPhoto(
        circle.teacherUid,
        fallbackUrl: circle.teacherProfilePhoto,
      ),
      initialData: circle.teacherProfilePhoto,
      builder: (context, snapshot) {
        final photoUrl = (snapshot.data ?? circle.teacherProfilePhoto).trim();
        return ProfileAvatar(
          name: teacherName,
          photoUrl: photoUrl,
          radius: radius,
          fallbackBg: fallbackBg,
          fallbackFg: fallbackFg,
          borderColor: borderColor,
        );
      },
    );
  }

  List<_OnlineCircle> _parseCircles(dynamic value) {
    if (value is! Map) return [];

    final raw = Map<dynamic, dynamic>.from(value);
    final out = <_OnlineCircle>[];

    raw.forEach((key, val) {
      if (val is! Map) return;
      final m = val.map((k, v) => MapEntry(k.toString(), v));

      final circle = _OnlineCircle(
        id: _safe(m['circle_id']).isNotEmpty
            ? _safe(m['circle_id'])
            : key.toString(),
        topic: _safe(m['topic']).isNotEmpty
            ? _safe(m['topic'])
            : 'Untitled Circle',
        description: _safe(m['description']),
        meetingUrl: _safe(m['meeting_url']),
        teacherUid: _safe(m['teacher_uid']),
        teacherName: _safe(m['teacher_name']),
        teacherProfilePhoto: _safe(m['teacher_profile_photo']),
        circleImageUrl: _safe(m['circle_image_url']),
        status: _safe(m['status']).toLowerCase(),
        timeMs: _toInt(m['time']),
        durationMinutes: _toInt(m['duration']),
        createdAtMs: _toInt(m['createdAt']),
        updatedAtMs: _toInt(m['updatedAt']),
      );

      if (circle.timeMs > 0 && circle.meetingUrl.isNotEmpty) {
        out.add(circle);
      }
    });

    out.sort((a, b) => a.timeMs.compareTo(b.timeMs));
    return out;
  }

  int _nearestUpcomingIndex(List<_OnlineCircle> circles) {
    if (circles.isEmpty) return 0;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    for (var i = 0; i < circles.length; i++) {
      if (circles[i].timeMs >= nowMs) return i;
    }
    return circles.length - 1;
  }

  void _ensureCarouselAnchor(List<_OnlineCircle> circles) {
    if (circles.isEmpty) {
      _openCirclesSignature = '';
      _activeIndex = 0;
      return;
    }

    final signature = circles
        .map((c) => '${c.id}_${c.updatedAtMs}_${c.timeMs}_${c.status}')
        .join('|');
    if (signature == _openCirclesSignature) return;

    _openCirclesSignature = signature;
    final target = _nearestUpcomingIndex(circles);
    _activeIndex = target;
    debugPrint(
      '[OnlineCircle][Guest] Carousel anchored. total=${circles.length} targetIndex=$target targetId=${circles[target].id}',
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pageController.hasClients) return;
      _pageController.jumpToPage(target);
      setState(() => _activeIndex = target);
    });
  }

  bool _isPastCircle(_OnlineCircle circle, DateTime now) {
    final start = DateTime.fromMillisecondsSinceEpoch(circle.timeMs);
    final end = start.add(
      Duration(
        minutes: circle.durationMinutes <= 0 ? 60 : circle.durationMinutes,
      ),
    );
    return now.isAfter(end);
  }

  String _countdownLabel(_OnlineCircle circle, DateTime now) {
    final start = DateTime.fromMillisecondsSinceEpoch(circle.timeMs);
    final openFrom = start.subtract(const Duration(minutes: 5));
    final end = start.add(
      Duration(
        minutes: circle.durationMinutes <= 0 ? 60 : circle.durationMinutes,
      ),
    );

    if (now.isAfter(end)) return 'Ended';
    if (now.isAfter(openFrom)) return 'Live now';

    final diff = start.difference(now);
    final total = diff.inSeconds.clamp(0, 864000);
    return 'Starts in ${_formatCompactCountdown(total)}';
  }

  Widget _circleHeroImage({
    required _OnlineCircle circle,
    required bool isPast,
  }) {
    final imageUrl = circle.circleImageUrl.trim();

    Widget fallbackImage({bool broken = false}) {
      return Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Brand.primaryBlue.withValues(alpha: 0.96),
              Brand.actionOrange.withValues(alpha: 0.88),
            ],
          ),
        ),
        child: Center(
          child: Icon(
            broken ? Icons.broken_image_outlined : Icons.groups_rounded,
            color: Colors.white,
            size: broken ? 42 : 52,
          ),
        ),
      );
    }

    Widget liveTeacherImage(String photoUrl) {
      final liveUrl = photoUrl.trim();
      if (liveUrl.isEmpty) return fallbackImage();
      return Image.network(
        liveUrl,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => fallbackImage(broken: true),
      );
    }

    Widget child;
    if (imageUrl.isEmpty) {
      child = FutureBuilder<String>(
        future: _resolveTeacherPhoto(
          circle.teacherUid,
          fallbackUrl: circle.teacherProfilePhoto,
        ),
        initialData: circle.teacherProfilePhoto,
        builder: (context, snapshot) {
          return liveTeacherImage(snapshot.data ?? circle.teacherProfilePhoto);
        },
      );
    } else {
      child = Image.network(
        imageUrl,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => FutureBuilder<String>(
          future: _resolveTeacherPhoto(
            circle.teacherUid,
            fallbackUrl: circle.teacherProfilePhoto,
          ),
          initialData: circle.teacherProfilePhoto,
          builder: (context, snapshot) {
            return liveTeacherImage(
              snapshot.data ?? circle.teacherProfilePhoto,
            );
          },
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withValues(alpha: isPast ? 0.38 : 0.14),
                Colors.black.withValues(alpha: isPast ? 0.62 : 0.38),
              ],
            ),
          ),
        ),
        if (isPast)
          Container(color: const Color(0xFF9E9E9E).withValues(alpha: 0.36)),
      ],
    );
  }

  Widget _buildCircleCarouselCard({
    required BuildContext context,
    required _OnlineCircle circle,
    required DateTime now,
    required bool active,
  }) {
    final isPast = _isPastCircle(circle, now);
    final countdown = _countdownLabel(circle, now);
    final teacherName = circle.teacherName.trim().isEmpty
        ? 'Teacher'
        : circle.teacherName.trim();
    final badgeColor = _statusColor(countdown);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOut,
      margin: EdgeInsets.only(top: active ? 4 : 14, bottom: active ? 4 : 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: active
              ? Brand.primaryBlue.withValues(alpha: 0.35)
              : Brand.uiBorder,
          width: active ? 1.4 : 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: active ? 0.14 : 0.08),
            blurRadius: active ? 22 : 14,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: () => _showCircleDetails(circle),
        child: Column(
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(24),
                ),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: _circleHeroImage(circle: circle, isPast: isPast),
                    ),
                    Positioned(
                      top: 12,
                      right: 12,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: badgeColor,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          countdown,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w900,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: 12,
                      bottom: 12,
                      child: Row(
                        children: [
                          _liveTeacherAvatar(
                            circle: circle,
                            teacherName: teacherName,
                            radius: 16,
                            fallbackBg: Colors.white.withValues(alpha: 0.28),
                            fallbackFg: Colors.white,
                            borderColor: Colors.white.withValues(alpha: 0.72),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            teacherName,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    circle.topic,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 16,
                      color: isPast
                          ? Brand.mainText.withValues(alpha: 0.75)
                          : Brand.primaryBlue,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _formatDateTime(circle.timeMs),
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: Brand.mainText.withValues(
                        alpha: isPast ? 0.56 : 0.78,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _statusColor(String countdown) {
    return switch (countdown) {
      'Live now' => Brand.actionOrange,
      'Ended' => const Color(0xFF757575),
      _ => Brand.primaryBlue,
    };
  }

  Future<void> _prefetchCircles() async {
    try {
      final snap = await _circlesRef.get();
      final circles = _parseCircles(snap.value).where((c) {
        final status = c.status.toLowerCase();
        return status == 'open' || status.isEmpty;
      }).toList();
      debugPrint(
        '[OnlineCircle][Guest] Prefetch complete. openCircles=${circles.length}',
      );
      if (!mounted) return;
      setState(() {
        _prefetchedOpenCircles = circles;
        _prefetching = false;
      });
    } catch (e) {
      debugPrint('[OnlineCircle][Guest] Prefetch failed: $e');
      if (!mounted) return;
      setState(() => _prefetching = false);
    }
  }

  String _two(int n) => n < 10 ? '0$n' : '$n';

  String _formatDateTime(int ms) {
    if (ms <= 0) return '-';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.year}-${_two(d.month)}-${_two(d.day)}  ${_two(d.hour)}:${_two(d.minute)}';
  }

  String _formatTimeOnly(int ms) {
    if (ms <= 0) return '-';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${_two(d.hour)}:${_two(d.minute)}';
  }

  Future<void> _showCircleDetails(_OnlineCircle circle) async {
    final teacherName = circle.teacherName.trim().isEmpty
        ? 'Teacher'
        : circle.teacherName.trim();

    await showDialog(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: Brand.uiBorder),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.10),
                blurRadius: 30,
                offset: const Offset(0, 18),
              ),
            ],
          ),
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _liveTeacherAvatar(
                  circle: circle,
                  teacherName: teacherName,
                  radius: 34,
                  fallbackBg: Brand.primaryBlue,
                  fallbackFg: Colors.white,
                  borderColor: Colors.white,
                ),
                const SizedBox(height: 14),
                Text(
                  circle.topic,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w900,
                    color: Brand.primaryBlue,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'with $teacherName',
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: Brand.mainText.withValues(alpha: 0.76),
                  ),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    _PrettyChip(
                      icon: MainIcons.schedule,
                      label: _formatTimeOnly(circle.timeMs),
                    ),
                    _PrettyChip(
                      icon: MainIcons.timer,
                      label: '${circle.durationMinutes} min',
                    ),
                    _PrettyChip(
                      icon: MainIcons.info,
                      label: circle.status.isEmpty ? 'open' : circle.status,
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Brand.appBg,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: Brand.uiBorder),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _DetailRow(
                        icon: MainIcons.calendar,
                        label: 'Date & time',
                        value: _formatDateTime(circle.timeMs),
                      ),
                      const SizedBox(height: 10),
                      const _DetailRow(
                        icon: MainIcons.accessTime,
                        label: 'Join rule',
                        value:
                            'Users can join from 5 minutes before start until the circle duration ends.',
                      ),
                      if (circle.description.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        _DetailRow(
                          icon: MainIcons.notes,
                          label: 'Description',
                          value: circle.description,
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                StreamBuilder<int>(
                  stream: Stream.periodic(const Duration(seconds: 1), (x) => x),
                  initialData: 0,
                  builder: (context, _) {
                    final now = DateTime.now();
                    final joinState = circle.joinStateAt(now);
                    final start = DateTime.fromMillisecondsSinceEpoch(
                      circle.timeMs,
                    );
                    final openFrom = start.subtract(const Duration(minutes: 5));
                    final openUntil = start.add(
                      Duration(
                        minutes: circle.durationMinutes <= 0
                            ? 60
                            : circle.durationMinutes,
                      ),
                    );
                    final joinLabel = joinButtonLabelForWindow(
                      openFrom: openFrom,
                      openUntil: openUntil,
                      hasMeetLink: circle.meetingUrl.trim().isNotEmpty,
                      now: now,
                      actionLabel: 'Join',
                      closedLabel: 'Join closed',
                    );

                    return Column(
                      children: [
                        _CircleJoinStatusBanner(
                          state: joinState,
                          circle: circle,
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: () => Navigator.of(context).pop(),
                                style: OutlinedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 14,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                ),
                                child: const Text('Close'),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: FilledButton.icon(
                                onPressed: joinState.canJoin
                                    ? () async {
                                        Navigator.of(context).pop();
                                        await _joinCircle(circle);
                                      }
                                    : null,
                                style: FilledButton.styleFrom(
                                  backgroundColor: Brand.primaryBlue,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 14,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                ),
                                icon: const Icon(Icons.video_call_rounded),
                                label: Text(joinLabel),
                              ),
                            ),
                          ],
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _joinCircle(_OnlineCircle circle) async {
    final state = circle.joinStateAt(DateTime.now());

    if (!state.canJoin) {
      if (!mounted) return;
      AppToast.show(context, state.message, type: AppToastType.info);
      return;
    }

    final uri = Uri.tryParse(circle.meetingUrl);
    if (uri == null) {
      if (!mounted) return;
      AppToast.show(context, 'Invalid meeting link.', type: AppToastType.error);
      return;
    }

    debugPrint(
      '[OnlineCircle][Guest] Attempting join for circleId=${circle.id} topic="${circle.topic}"',
    );
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);

    if (!ok && mounted) {
      AppToast.show(
        context,
        'Could not open Google Meet.',
        type: AppToastType.error,
      );
      debugPrint(
        '[OnlineCircle][Guest] Launch failed for circleId=${circle.id}',
      );
    } else {
      debugPrint(
        '[OnlineCircle][Guest] Launch succeeded for circleId=${circle.id}',
      );
    }
  }

  Future<void> _openCirclesFullscreen() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) {
          return Scaffold(
            backgroundColor: Brand.appBg,
            body: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                child: StreamBuilder<int>(
                  stream: Stream.periodic(const Duration(seconds: 1), (x) => x),
                  initialData: 0,
                  builder: (context, _) {
                    final now = DateTime.now();
                    final screenHeight = MediaQuery.of(context).size.height;
                    final carouselHeight = (screenHeight * 0.62)
                        .clamp(300.0, 560.0)
                        .toDouble();

                    return StreamBuilder<DatabaseEvent>(
                      stream: _circlesRef.onValue,
                      builder: (context, snap) {
                        if (snap.hasError) {
                          return const Center(
                            child: Text('Could not load circles.'),
                          );
                        }

                        if (!snap.hasData && _prefetching) {
                          return const Center(child: YbsBusyLogo());
                        }

                        final source = snap.hasData
                            ? _parseCircles(snap.data?.snapshot.value)
                            : _prefetchedOpenCircles;
                        final circles = source.where((c) {
                          final status = c.status.toLowerCase();
                          return status == 'open' || status.isEmpty;
                        }).toList();

                        _ensureCarouselAnchor(circles);

                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                SizedBox(
                                  width: 44,
                                  height: 44,
                                  child: _buildOpenCircleTeacherIcon(
                                    circles: circles,
                                    size: 44,
                                    borderRadius: BorderRadius.circular(14),
                                    backgroundColor: Brand.primaryBlue
                                        .withValues(alpha: 0.10),
                                    fallbackIcon: Icons.groups_rounded,
                                    fallbackIconColor: Brand.primaryBlue,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                const Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Online Circles',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w900,
                                          fontSize: 20,
                                          color: Brand.primaryBlue,
                                        ),
                                      ),
                                      SizedBox(height: 2),
                                      Text(
                                        'Swipe left and right to browse.',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w700,
                                          color: Brand.mainText,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  onPressed: () => Navigator.of(context).pop(),
                                  icon: const Icon(Icons.close_rounded),
                                ),
                              ],
                            ),
                            const SizedBox(height: 14),
                            if (circles.isEmpty)
                              Expanded(
                                child: Center(
                                  child: CardShell(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Container(
                                          width: 60,
                                          height: 60,
                                          decoration: BoxDecoration(
                                            color: Brand.primaryBlue.withValues(
                                              alpha: 0.10,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              18,
                                            ),
                                          ),
                                          child: const Icon(
                                            Icons.event_busy_rounded,
                                            color: Brand.primaryBlue,
                                          ),
                                        ),
                                        const SizedBox(height: 12),
                                        const Text(
                                          'No online circles available.',
                                          style: TextStyle(
                                            fontWeight: FontWeight.w900,
                                            color: Brand.primaryBlue,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              )
                            else ...[
                              SizedBox(
                                height: carouselHeight,
                                child: PageView.builder(
                                  controller: _pageController,
                                  itemCount: circles.length,
                                  onPageChanged: (i) =>
                                      setState(() => _activeIndex = i),
                                  itemBuilder: (context, index) {
                                    final circle = circles[index];
                                    final safeIndex = _activeIndex.clamp(
                                      0,
                                      circles.length - 1,
                                    );
                                    final active = index == safeIndex;
                                    return Transform.scale(
                                      scale: active ? 1.0 : 0.95,
                                      child: Opacity(
                                        opacity: active ? 1 : 0.84,
                                        child: _buildCircleCarouselCard(
                                          context: context,
                                          circle: circle,
                                          now: now,
                                          active: active,
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                              const SizedBox(height: 10),
                              Center(
                                child: Wrap(
                                  spacing: 6,
                                  children: List.generate(circles.length, (i) {
                                    final active = i == _activeIndex;
                                    return AnimatedContainer(
                                      duration: const Duration(
                                        milliseconds: 200,
                                      ),
                                      width: active ? 18 : 8,
                                      height: 8,
                                      decoration: BoxDecoration(
                                        color: active
                                            ? Brand.primaryBlue
                                            : Brand.primaryBlue.withValues(
                                                alpha: 0.24,
                                              ),
                                        borderRadius: BorderRadius.circular(
                                          999,
                                        ),
                                      ),
                                    );
                                  }),
                                ),
                              ),
                              const SizedBox(height: 10),
                              const Center(
                                child: Text(
                                  'Tap a card to open details and join options.',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    color: Brand.mainText,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        );
                      },
                    );
                  },
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: _prefetchedOpenCircles.isNotEmpty
            ? _openCirclesFullscreen
            : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Brand.uiBorder),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (_prefetching)
                const SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                )
              else
                SizedBox(
                  width: 32,
                  height: 32,
                  child: _buildOpenCircleTeacherIcon(
                    circles: _prefetchedOpenCircles,
                    size: 32,
                    borderRadius: BorderRadius.circular(999),
                    backgroundColor: const Color(
                      0xFF0B8F87,
                    ).withValues(alpha: 0.10),
                    fallbackIcon: Icons.groups_rounded,
                    fallbackIconColor: const Color(0xFF0B8F87),
                    fallbackIconSize: 20,
                  ),
                ),
              const SizedBox(height: 6),
              const Text(
                'Circles',
                style: TextStyle(
                  color: Brand.primaryBlue,
                  fontWeight: FontWeight.w800,
                  fontSize: 12,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OnlineCircle {
  final String id;
  final String topic;
  final String description;
  final String meetingUrl;
  final String teacherUid;
  final String teacherName;
  final String teacherProfilePhoto;
  final String circleImageUrl;
  final String status;
  final int timeMs;
  final int durationMinutes;
  final int createdAtMs;
  final int updatedAtMs;

  const _OnlineCircle({
    required this.id,
    required this.topic,
    required this.description,
    required this.meetingUrl,
    required this.teacherUid,
    required this.teacherName,
    required this.teacherProfilePhoto,
    required this.circleImageUrl,
    required this.status,
    required this.timeMs,
    required this.durationMinutes,
    required this.createdAtMs,
    required this.updatedAtMs,
  });

  _CircleJoinState joinStateAt(DateTime now) {
    final start = DateTime.fromMillisecondsSinceEpoch(timeMs);
    final openFrom = start.subtract(const Duration(minutes: 5));
    final end = start.add(
      Duration(minutes: durationMinutes <= 0 ? 60 : durationMinutes),
    );

    if (now.isBefore(openFrom)) {
      final diff = start.difference(now);
      final total = diff.inSeconds.clamp(0, 864000);
      return _CircleJoinState(
        canJoin: false,
        message: 'Live in: ${_formatCompactCountdown(total)}',
      );
    }

    if (now.isAfter(end)) {
      return const _CircleJoinState(
        canJoin: false,
        message: 'This class has already ended.',
      );
    }

    return const _CircleJoinState(
      canJoin: true,
      message: 'You can join this class now.',
    );
  }
}

class _CircleJoinState {
  final bool canJoin;
  final String message;

  const _CircleJoinState({required this.canJoin, required this.message});
}

class _RotatingTeacherPhotoIcon extends StatefulWidget {
  const _RotatingTeacherPhotoIcon({
    required this.photoUrls,
    required this.size,
    required this.borderRadius,
    required this.backgroundColor,
    required this.fallbackIcon,
    required this.fallbackIconColor,
    this.fallbackIconSize = 24,
  });

  final List<String> photoUrls;
  final double size;
  final BorderRadius borderRadius;
  final Color backgroundColor;
  final IconData fallbackIcon;
  final Color fallbackIconColor;
  final double fallbackIconSize;

  @override
  State<_RotatingTeacherPhotoIcon> createState() =>
      _RotatingTeacherPhotoIconState();
}

class _RotatingTeacherPhotoIconState extends State<_RotatingTeacherPhotoIcon> {
  Timer? _timer;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _configureTimer();
  }

  @override
  void didUpdateWidget(covariant _RotatingTeacherPhotoIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldPhotos = oldWidget.photoUrls;
    final newPhotos = widget.photoUrls;
    if (!listEquals(oldPhotos, newPhotos)) {
      _index = 0;
      _configureTimer();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _configureTimer() {
    _timer?.cancel();
    if (widget.photoUrls.length <= 1) return;
    _timer = Timer.periodic(const Duration(milliseconds: 2500), (_) {
      if (!mounted) return;
      setState(() {
        _index = (_index + 1) % widget.photoUrls.length;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final photos = widget.photoUrls;
    final currentUrl = photos.isEmpty ? '' : photos[_index % photos.length];

    return ClipRRect(
      borderRadius: widget.borderRadius,
      child: Container(
        width: widget.size,
        height: widget.size,
        color: widget.backgroundColor,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 350),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          transitionBuilder: (child, animation) =>
              FadeTransition(opacity: animation, child: child),
          child: currentUrl.isEmpty
              ? Center(
                  key: const ValueKey('fallback'),
                  child: Icon(
                    widget.fallbackIcon,
                    color: widget.fallbackIconColor,
                    size: widget.fallbackIconSize,
                  ),
                )
              : Image.network(
                  currentUrl,
                  key: ValueKey(currentUrl),
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => Center(
                    child: Icon(
                      widget.fallbackIcon,
                      color: widget.fallbackIconColor,
                      size: widget.fallbackIconSize,
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}

class _CircleJoinStatusBanner extends StatelessWidget {
  final _CircleJoinState state;
  final _OnlineCircle circle;

  const _CircleJoinStatusBanner({required this.state, required this.circle});

  @override
  Widget build(BuildContext context) {
    final isOpen = state.canJoin;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isOpen
            ? Brand.actionOrange.withValues(alpha: 0.10)
            : Brand.primaryBlue.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: isOpen ? Brand.actionOrange : Brand.uiBorder),
      ),
      child: Row(
        children: [
          Icon(
            isOpen ? Icons.check_circle_rounded : Icons.info_outline_rounded,
            color: isOpen ? Brand.actionOrange : Brand.primaryBlue,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              state.message,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: isOpen ? Brand.actionOrange : Brand.primaryBlue,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _DetailRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: Brand.primaryBlue),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: Brand.mainText.withValues(alpha: 0.65),
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  color: Brand.primaryBlue,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _GalleryShimmer extends StatefulWidget {
  const _GalleryShimmer();

  @override
  State<_GalleryShimmer> createState() => _GalleryShimmerState();
}

class _GalleryShimmerState extends State<_GalleryShimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final opacity = 0.25 + _controller.value * 0.5;
        return Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
          child: Opacity(
            opacity: opacity,
            child: GridView.count(
              crossAxisCount: 4,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
              childAspectRatio: 1,
              physics: const NeverScrollableScrollPhysics(),
              children: List.generate(12, (_) => _buildSkeletonCard()),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSkeletonCard() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.grey.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
      ),
    );
  }
}

class _PublicGalleryShowcase extends StatefulWidget {
  const _PublicGalleryShowcase();

  @override
  State<_PublicGalleryShowcase> createState() => _PublicGalleryShowcaseState();
}

class _PublicGalleryShowcaseState extends State<_PublicGalleryShowcase> {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  String _mediaFilter = 'all';
  String? _selectedTeacherUid;

  DatabaseReference _galleryRef() => _db.child('public_gallery_teasers');
  DatabaseReference _learnerGalleryRef() => _db.child('learner_gallery');
  DatabaseReference _teachersRef() => _db.child('website/teachers');

  List<Map<String, dynamic>> _itemsFromSnapshot(dynamic value) {
    if (value is! Map) return [];

    final raw = Map<dynamic, dynamic>.from(value);
    final out = <Map<String, dynamic>>[];

    raw.forEach((key, val) {
      if (val is! Map) return;

      final m = val.map((k, vv) => MapEntry(k.toString(), vv));
      out.add({'id': key.toString(), ...m});
    });

    out.sort((a, b) {
      final aTs = _toInt(a['createdAt']);
      final bTs = _toInt(b['createdAt']);
      return bTs.compareTo(aTs);
    });

    return out;
  }

  static int _toInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  List<Map<String, dynamic>> _applyFilter(List<Map<String, dynamic>> items) {
    if (_mediaFilter == 'all') return items;

    return items.where((item) {
      final type = (item['type'] ?? '').toString().trim().toLowerCase();
      return type == _mediaFilter;
    }).toList();
  }

  List<Map<String, dynamic>> _teacherShowcaseFromSnapshots({
    required dynamic learnerGalleryValue,
    required dynamic teachersValue,
  }) {
    final grouped = <String, Map<String, dynamic>>{};
    final teacherProfiles = <String, Map<String, dynamic>>{};

    if (teachersValue is Map) {
      final teachersMap = Map<dynamic, dynamic>.from(teachersValue);
      teachersMap.forEach((key, value) {
        if (value is! Map) return;
        teacherProfiles[key.toString().trim()] = value.map(
          (k, vv) => MapEntry(k.toString(), vv),
        );
      });
    }

    if (learnerGalleryValue is! Map) return const [];
    final learnerMap = Map<dynamic, dynamic>.from(learnerGalleryValue);

    learnerMap.forEach((_, itemsValue) {
      if (itemsValue is! Map) return;
      final itemsMap = Map<dynamic, dynamic>.from(itemsValue);

      itemsMap.forEach((itemId, itemValue) {
        if (itemValue is! Map) return;
        final item = itemValue.map((k, vv) => MapEntry(k.toString(), vv));

        final type = (item['type'] ?? '').toString().trim().toLowerCase();
        final url = (item['url'] ?? '').toString().trim();
        final teacherUid = (item['teacherUid'] ?? '').toString().trim();
        if (teacherUid.isEmpty || url.isEmpty) return;
        if (type != 'photo' && type != 'video') return;

        final profile = teacherProfiles[teacherUid];
        final profileMap = (profile?['profile'] is Map)
            ? Map<dynamic, dynamic>.from(profile!['profile'] as Map)
            : <dynamic, dynamic>{};

        String profilePhoto = (profileMap['profile_photo'] ?? '')
            .toString()
            .trim();

        if (profilePhoto.isEmpty && profileMap['profile_photos'] is List) {
          for (final raw in (profileMap['profile_photos'] as List)) {
            final candidate = raw.toString().trim();
            if (candidate.isNotEmpty) {
              profilePhoto = candidate;
              break;
            }
          }
        }

        final firstName = (profile?['first_name'] ?? '').toString().trim();
        final lastName = (profile?['last_name'] ?? '').toString().trim();
        final profileName = ('$firstName $lastName').trim();
        final teacherName = (item['teacherName'] ?? '').toString().trim();
        final displayName = teacherName.isNotEmpty
            ? teacherName
            : (profileName.isNotEmpty ? profileName : 'Teacher');

        final entry = grouped.putIfAbsent(teacherUid, () {
          return {
            'uid': teacherUid,
            'name': displayName,
            'photoUrl': profilePhoto,
            'items': <Map<String, dynamic>>[],
            'latestTs': 0,
          };
        });

        if ((entry['photoUrl'] ?? '').toString().trim().isEmpty &&
            profilePhoto.isNotEmpty) {
          entry['photoUrl'] = profilePhoto;
        }

        final createdAt = _toInt(item['createdAt']);
        entry['latestTs'] = createdAt > _toInt(entry['latestTs'])
            ? createdAt
            : entry['latestTs'];

        (entry['items'] as List<Map<String, dynamic>>).add({
          'id': itemId.toString(),
          ...item,
        });
      });
    });

    final out = grouped.values.toList();
    for (final entry in out) {
      final list = (entry['items'] as List<Map<String, dynamic>>)
        ..sort(
          (a, b) => _toInt(b['createdAt']).compareTo(_toInt(a['createdAt'])),
        );
      entry['items'] = list;
    }

    out.sort((a, b) => _toInt(b['latestTs']).compareTo(_toInt(a['latestTs'])));
    return out;
  }

  Widget _buildFilterButton({required String value, required String label}) {
    final selected = _mediaFilter == value;

    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) {
        if (_mediaFilter == value) return;
        setState(() {
          _mediaFilter = value;
          if (value != 'teachers') _selectedTeacherUid = null;
        });
      },
      selectedColor: Brand.actionOrange.withValues(alpha: 0.16),
      checkmarkColor: Brand.actionOrange,
      labelStyle: TextStyle(
        color: selected ? Brand.actionOrange : Brand.primaryBlue,
        fontWeight: FontWeight.w800,
      ),
      side: BorderSide(
        color: selected
            ? Brand.actionOrange.withValues(alpha: 0.5)
            : Brand.uiBorder,
      ),
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
    );
  }

  Widget _buildTeacherAvatar({required String name, required String photoUrl}) {
    final cleanUrl = photoUrl.trim();
    final initial = (name.trim().isEmpty ? 'T' : name.trim()[0]).toUpperCase();

    return Container(
      width: 84,
      height: 84,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(
          colors: [Color(0xFFEAF2FF), Color(0xFFF8FBFF)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: Brand.uiBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: cleanUrl.isEmpty
          ? Center(
              child: Text(
                initial,
                style: const TextStyle(
                  color: Brand.primaryBlue,
                  fontWeight: FontWeight.w900,
                  fontSize: 30,
                ),
              ),
            )
          : Image.network(
              cleanUrl,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => Center(
                child: Text(
                  initial,
                  style: const TextStyle(
                    color: Brand.primaryBlue,
                    fontWeight: FontWeight.w900,
                    fontSize: 30,
                  ),
                ),
              ),
            ),
    );
  }

  Widget _buildTeachersShowcase() {
    return StreamBuilder<DatabaseEvent>(
      stream: _learnerGalleryRef().onValue,
      builder: (context, learnerSnap) {
        return StreamBuilder<DatabaseEvent>(
          stream: _teachersRef().onValue,
          builder: (context, teacherSnap) {
            final teachers = _teacherShowcaseFromSnapshots(
              learnerGalleryValue: learnerSnap.data?.snapshot.value,
              teachersValue: teacherSnap.data?.snapshot.value,
            );

            final hasSelected =
                _selectedTeacherUid != null &&
                teachers.any((t) => t['uid'] == _selectedTeacherUid);
            final selectedUid = hasSelected ? _selectedTeacherUid : null;

            if (teachers.isEmpty) {
              return const Center(
                child: Text(
                  'No teacher activity yet.',
                  style: TextStyle(
                    color: Brand.primaryBlue,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              );
            }

            if (selectedUid != null) {
              final selected = teachers.firstWhere(
                (t) => t['uid'] == selectedUid,
              );
              final selectedItems =
                  (selected['items'] as List<Map<String, dynamic>>);

              return Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 8, 18, 10),
                    child: Row(
                      children: [
                        OutlinedButton.icon(
                          onPressed: () {
                            setState(() => _selectedTeacherUid = null);
                          },
                          icon: const Icon(Icons.arrow_back_rounded),
                          label: const Text('Back to Teachers'),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            (selected['name'] ?? 'Teacher').toString(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Brand.primaryBlue,
                              fontWeight: FontWeight.w900,
                              fontSize: 18,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: GridView.builder(
                      padding: const EdgeInsets.fromLTRB(18, 6, 18, 18),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 4,
                            crossAxisSpacing: 8,
                            mainAxisSpacing: 8,
                            childAspectRatio: 1,
                          ),
                      itemCount: selectedItems.length,
                      itemBuilder: (context, index) {
                        final item = selectedItems[index];
                        final type = (item['type'] ?? '')
                            .toString()
                            .trim()
                            .toLowerCase();
                        final url = (item['url'] ?? '').toString().trim();
                        final thumbnailUrl = (item['thumbnailUrl'] ?? '')
                            .toString()
                            .trim();

                        return InkWell(
                          borderRadius: BorderRadius.circular(20),
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => _PublicGalleryViewerScreen(
                                  items: selectedItems,
                                  initialIndex: index,
                                ),
                              ),
                            );
                          },
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: Brand.uiBorder.withValues(alpha: 0.85),
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.04),
                                  blurRadius: 10,
                                  offset: const Offset(0, 6),
                                ),
                              ],
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(20),
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  if (type == 'video')
                                    _PublicGalleryVideoTile(
                                      url: url,
                                      thumbnailUrl: thumbnailUrl,
                                    )
                                  else
                                    _FastNetworkThumb(
                                      url: url,
                                      fit: BoxFit.cover,
                                    ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              );
            }

            return GridView.builder(
              padding: const EdgeInsets.fromLTRB(18, 6, 18, 18),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
                childAspectRatio: 0.92,
              ),
              itemCount: teachers.length,
              itemBuilder: (context, index) {
                final teacher = teachers[index];
                final name = (teacher['name'] ?? 'Teacher').toString();
                final photoUrl = (teacher['photoUrl'] ?? '').toString();
                final uid = (teacher['uid'] ?? '').toString();

                return InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: uid.isEmpty
                      ? null
                      : () {
                          setState(() => _selectedTeacherUid = uid);
                        },
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: Brand.uiBorder.withValues(alpha: 0.85),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.04),
                          blurRadius: 10,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _buildTeacherAvatar(name: name, photoUrl: photoUrl),
                        const SizedBox(height: 12),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          child: Text(
                            name,
                            maxLines: 2,
                            textAlign: TextAlign.center,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Brand.primaryBlue,
                              fontWeight: FontWeight.w900,
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return SoftBackground(
      child: Column(
        children: [
          Expanded(
            child: StreamBuilder<DatabaseEvent>(
              stream: _galleryRef().onValue,
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const _GalleryShimmer();
                }
                final items = _itemsFromSnapshot(snap.data?.snapshot.value);
                final visibleItems = _applyFilter(items);

                if (_mediaFilter == 'teachers') {
                  return Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(18, 8, 18, 10),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              _buildFilterButton(value: 'all', label: 'All'),
                              _buildFilterButton(
                                value: 'photo',
                                label: 'Photos',
                              ),
                              _buildFilterButton(
                                value: 'video',
                                label: 'Videos',
                              ),
                              _buildFilterButton(
                                value: 'teachers',
                                label: 'Teachers',
                              ),
                            ],
                          ),
                        ),
                      ),
                      Expanded(child: _buildTeachersShowcase()),
                    ],
                  );
                }

                if (items.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                      child: CardShell(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 54,
                              height: 54,
                              decoration: BoxDecoration(
                                color: Brand.accentCyan.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: Brand.uiBorder),
                              ),
                              child: const Icon(
                                Icons.photo_library_rounded,
                                color: Brand.primaryBlue,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'Gallery Coming Soon',
                              style: Theme.of(context).textTheme.titleLarge
                                  ?.copyWith(fontWeight: FontWeight.w900),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Public gallery teaser media will appear here.',
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
                                    color: Brand.mainText.withValues(
                                      alpha: 0.75,
                                    ),
                                    height: 1.4,
                                  ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }

                return Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 8, 18, 10),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            _buildFilterButton(value: 'all', label: 'All'),
                            _buildFilterButton(value: 'photo', label: 'Photos'),
                            _buildFilterButton(value: 'video', label: 'Videos'),
                            _buildFilterButton(
                              value: 'teachers',
                              label: 'Teachers',
                            ),
                          ],
                        ),
                      ),
                    ),
                    Expanded(
                      child: visibleItems.isEmpty
                          ? Center(
                              child: Text(
                                _mediaFilter == 'video'
                                    ? 'No videos yet.'
                                    : 'No photos yet.',
                                style: const TextStyle(
                                  color: Brand.primaryBlue,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            )
                          : GridView.builder(
                              padding: const EdgeInsets.fromLTRB(18, 6, 18, 18),
                              gridDelegate:
                                  const SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: 4,
                                    crossAxisSpacing: 8,
                                    mainAxisSpacing: 8,
                                    childAspectRatio: 1,
                                  ),
                              itemCount: visibleItems.length,
                              itemBuilder: (context, index) {
                                final item = visibleItems[index];
                                final type = (item['type'] ?? '')
                                    .toString()
                                    .trim()
                                    .toLowerCase();
                                final url = (item['url'] ?? '')
                                    .toString()
                                    .trim();
                                final thumbnailUrl =
                                    (item['thumbnailUrl'] ?? '')
                                        .toString()
                                        .trim();

                                return InkWell(
                                  borderRadius: BorderRadius.circular(20),
                                  onTap: () {
                                    Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (_) =>
                                            _PublicGalleryViewerScreen(
                                              items: visibleItems,
                                              initialIndex: index,
                                            ),
                                      ),
                                    );
                                  },
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      borderRadius: BorderRadius.circular(20),
                                      border: Border.all(
                                        color: Brand.uiBorder.withValues(
                                          alpha: 0.85,
                                        ),
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withValues(
                                            alpha: 0.04,
                                          ),
                                          blurRadius: 10,
                                          offset: const Offset(0, 6),
                                        ),
                                      ],
                                    ),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(20),
                                      child: Stack(
                                        fit: StackFit.expand,
                                        children: [
                                          if (type == 'video')
                                            _PublicGalleryVideoTile(
                                              url: url,
                                              thumbnailUrl: thumbnailUrl,
                                            )
                                          else
                                            _FastNetworkThumb(
                                              url: url,
                                              fit: BoxFit.cover,
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _PublicGalleryVideoTile extends StatefulWidget {
  const _PublicGalleryVideoTile({required this.url, this.thumbnailUrl});

  final String url;
  final String? thumbnailUrl;

  @override
  State<_PublicGalleryVideoTile> createState() =>
      _PublicGalleryVideoTileState();
}

class _PublicGalleryVideoTileState extends State<_PublicGalleryVideoTile> {
  VideoPlayerController? _controller;
  bool _ready = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    if (widget.thumbnailUrl == null || widget.thumbnailUrl!.isEmpty) {
      _init();
    }
  }

  Future<void> _init() async {
    try {
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(widget.url),
      );
      await controller.initialize().timeout(const Duration(seconds: 10));
      await controller.setLooping(false);
      await controller.pause();
      await controller.seekTo(Duration.zero);
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _ready = true;
        _failed = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _ready = false;
      });
    }
  }

  @override
  void dispose() {
    final c = _controller;
    _controller = null;
    c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.thumbnailUrl != null && widget.thumbnailUrl!.isNotEmpty) {
      return Stack(
        fit: StackFit.expand,
        children: [
          Image.network(
            widget.thumbnailUrl!,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
          Container(color: Colors.black.withValues(alpha: 0.18)),
          const Center(
            child: Icon(
              Icons.play_circle_fill_rounded,
              color: Colors.white,
              size: 26,
            ),
          ),
        ],
      );
    }

    if (_failed) {
      return Container(
        color: Colors.black,
        alignment: Alignment.center,
        child: const Icon(
          Icons.broken_image_outlined,
          color: Colors.white,
          size: 34,
        ),
      );
    }

    if (!_ready || _controller == null) {
      return Container(
        color: Colors.black,
        child: const Center(
          child: CircularProgressIndicator(color: Colors.white),
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        FittedBox(
          fit: BoxFit.cover,
          clipBehavior: Clip.hardEdge,
          child: SizedBox(
            width: _controller!.value.size.width,
            height: _controller!.value.size.height,
            child: VideoPlayer(_controller!),
          ),
        ),
        Container(color: Colors.black.withValues(alpha: 0.18)),
        const Center(
          child: Icon(
            Icons.play_circle_fill_rounded,
            color: Colors.white,
            size: 26,
          ),
        ),
      ],
    );
  }
}

class _PublicGalleryViewerScreen extends StatefulWidget {
  const _PublicGalleryViewerScreen({
    required this.items,
    required this.initialIndex,
  });

  final List<Map<String, dynamic>> items;
  final int initialIndex;

  @override
  State<_PublicGalleryViewerScreen> createState() =>
      _PublicGalleryViewerScreenState();
}

class _PublicGalleryViewerScreenState
    extends State<_PublicGalleryViewerScreen> {
  late final PageController _pageController;
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: _currentIndex);
    _precacheAdjacent(_currentIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _precacheAdjacent(int index) {
    for (final offset in [-2, -1, 0, 1, 2]) {
      final i = index + offset;
      if (i < 0 || i >= widget.items.length) continue;
      final type = (widget.items[i]['type'] ?? '')
          .toString()
          .trim()
          .toLowerCase();
      if (type == 'video') continue;
      final url = (widget.items[i]['url'] ?? '').toString().trim();
      if (url.isNotEmpty) {
        precacheImage(NetworkImage(url), context);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(
          '${_currentIndex + 1} / ${widget.items.length}',
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
      body: PageView.builder(
        controller: _pageController,
        itemCount: widget.items.length,
        onPageChanged: (i) {
          setState(() => _currentIndex = i);
          _precacheAdjacent(i);
        },
        itemBuilder: (context, index) {
          final item = widget.items[index];
          final type = (item['type'] ?? '').toString().trim().toLowerCase();
          final url = (item['url'] ?? '').toString().trim();
          final thumbnailUrl = (item['thumbnailUrl'] ?? '').toString().trim();
          final isVideo = type == 'video';

          if (isVideo) {
            return Center(child: _PublicGalleryViewerVideo(url: url));
          }

          return Stack(
            children: [
              if (thumbnailUrl.isNotEmpty)
                Positioned.fill(
                  child: Center(
                    child: CachedNetworkImage(
                      imageUrl: thumbnailUrl,
                      fit: BoxFit.contain,
                      memCacheWidth: 440,
                      errorWidget: (_, _, _) => const SizedBox.shrink(),
                    ),
                  ),
                ),
              Center(
                child: InteractiveViewer(
                  minScale: 0.8,
                  maxScale: 4,
                  child: CachedNetworkImage(
                    imageUrl: url,
                    fit: BoxFit.contain,
                    placeholder: (_, _) => thumbnailUrl.isNotEmpty
                        ? const SizedBox.shrink()
                        : const SizedBox(
                            height: 260,
                            child: Center(
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2,
                              ),
                            ),
                          ),
                    progressIndicatorBuilder: (context, _, progress) {
                      return Center(
                        child: CircularProgressIndicator(
                          value: progress.progress,
                          color: Colors.white54,
                          strokeWidth: 2.5,
                        ),
                      );
                    },
                    errorWidget: (_, _, _) => const Icon(
                      Icons.broken_image_outlined,
                      color: Colors.white,
                      size: 44,
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _PublicGalleryViewerVideo extends StatefulWidget {
  const _PublicGalleryViewerVideo({required this.url});

  final String url;

  @override
  State<_PublicGalleryViewerVideo> createState() =>
      _PublicGalleryViewerVideoState();
}

class _PublicGalleryViewerVideoState extends State<_PublicGalleryViewerVideo> {
  VideoPlayerController? _controller;
  bool _ready = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(widget.url),
      );
      await controller.initialize();
      controller.setLooping(false);

      if (!mounted) {
        await controller.dispose();
        return;
      }

      setState(() {
        _controller = controller;
        _ready = true;
        _failed = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _ready = false;
      });
    }
  }

  @override
  void dispose() {
    final c = _controller;
    _controller = null;
    c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      return const Icon(
        Icons.broken_image_outlined,
        color: Colors.white,
        size: 44,
      );
    }

    if (!_ready || _controller == null) {
      return const SizedBox(
        width: 40,
        height: 40,
        child: YbsBusyLogo(size: 36, color: Colors.white),
      );
    }

    return AspectRatio(
      aspectRatio: _controller!.value.aspectRatio,
      child: Stack(
        alignment: Alignment.center,
        children: [
          VideoPlayer(_controller!),
          IconButton(
            onPressed: () {
              if (_controller!.value.isPlaying) {
                _controller!.pause();
              } else {
                _controller!.play();
              }
              setState(() {});
            },
            iconSize: 60,
            color: Colors.white,
            icon: Icon(
              _controller!.value.isPlaying
                  ? Icons.pause_circle_filled_rounded
                  : Icons.play_circle_fill_rounded,
            ),
          ),
        ],
      ),
    );
  }
}

class _FastNetworkThumb extends StatelessWidget {
  const _FastNetworkThumb({required this.url, this.fit = BoxFit.cover});

  final String url;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    return Image.network(
      url,
      fit: fit,
      filterQuality: FilterQuality.low,
      cacheWidth: 720,
      loadingBuilder: (context, child, progress) {
        if (progress == null) return child;
        return Container(
          color: const Color(0xFFEFF3F8),
          alignment: Alignment.center,
          child: const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        );
      },
      errorBuilder: (_, _, _) => Container(
        color: const Color(0xFFEFF3F8),
        alignment: Alignment.center,
        child: const Icon(Icons.broken_image_outlined),
      ),
    );
  }
}

class _CourseLite {
  _CourseLite({
    required this.id,
    required this.title,
    required this.thumb,
    required this.shortDesc,
    required this.longDesc,
    required this.duration,
    required this.level,
    required this.language,
    required this.deliveryOptions,
    required this.deliveryOptionRaw,
    required this.deliveryConfigs,
    required this.requirements,
    required this.tags,
    required this.status,
    required this.category,
    required this.content,
    required this.instructors,
    required this.orderIndex,
    required this.updatedAt,
  });

  final String id;
  final String category;
  final String title;
  final String thumb;
  final String shortDesc;
  final String longDesc;
  final String content;
  final String duration;
  final String level;
  final String language;
  final List<String> deliveryOptions;
  final String deliveryOptionRaw;
  final Map<String, _DeliveryConfigLite> deliveryConfigs;
  final List<_InstructorLite> instructors;
  final int? orderIndex;
  final String requirements;
  final List<String> tags;
  final String status;
  final int? updatedAt;

  static List<String> _parseList(dynamic v) {
    if (v == null) return [];

    if (v is List) {
      return v.map((e) => e.toString()).toList();
    }

    if (v is Map) {
      final entries = v.entries.toList()
        ..sort((a, b) => a.key.toString().compareTo(b.key.toString()));
      return entries.map((e) => e.value.toString()).toList();
    }

    if (v is String) {
      return v
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }

    return [];
  }

  static List<_InstructorLite> _parseInstructors(dynamic v) {
    final out = <_InstructorLite>[];

    if (v == null) return out;

    void addInstructor(String uid, String name) {
      final cleanUid = uid.trim();
      final cleanName = name.trim();
      if (cleanUid.isNotEmpty || cleanName.isNotEmpty) {
        out.add(_InstructorLite(uid: cleanUid, name: cleanName));
      }
    }

    void addInstructorFromMap(Map map, {String fallbackUid = ''}) {
      final mm = map.map((k, vv) => MapEntry(k.toString(), vv));
      final uid = (mm['uid'] ?? fallbackUid).toString().trim();
      final name = (mm['name'] ?? '').toString().trim();
      addInstructor(uid, name);
    }

    void addInstructorFromString(String raw) {
      final s = raw.trim();
      if (s.isEmpty) return;

      final mapLike = RegExp(r'^\{\s*uid:\s*(.+?),\s*name:\s*(.+?)\s*\}$');
      final match = mapLike.firstMatch(s);
      if (match != null) {
        final uid = (match.group(1) ?? '').trim();
        final name = (match.group(2) ?? '').trim();
        addInstructor(uid, name);
        return;
      }

      addInstructor('', s);
    }

    if (v is List) {
      for (final item in v) {
        if (item is Map) {
          addInstructorFromMap(item);
        } else {
          addInstructorFromString(item.toString());
        }
      }
      return out;
    }

    if (v is Map) {
      final vm = v.map((k, vv) => MapEntry(k.toString(), vv));

      if (vm.containsKey('uid') || vm.containsKey('name')) {
        addInstructorFromMap(vm);
        return out;
      }

      final entries = vm.entries.toList()
        ..sort((a, b) => a.key.toString().compareTo(b.key.toString()));

      for (final e in entries) {
        final key = e.key.toString().trim();
        final item = e.value;

        if (item is Map) {
          addInstructorFromMap(item, fallbackUid: key);
        } else {
          addInstructor(key, item.toString());
        }
      }
      return out;
    }

    if (v is String) {
      final s = v.trim();

      if (s.startsWith('{') && s.contains('uid:') && s.contains('name:')) {
        addInstructorFromString(s);
        return out;
      }

      final parts = s
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty);
      for (final name in parts) {
        addInstructor('', name);
      }
    }

    return out;
  }

  static Map<String, _DeliveryConfigLite> _parseDeliveryConfigs(dynamic v) {
    if (v is! Map) return {};

    final out = <String, _DeliveryConfigLite>{};

    v.forEach((key, value) {
      final k = key.toString().trim().toLowerCase();
      if (k.isEmpty || value is! Map) return;

      final m = value.map((kk, vv) => MapEntry(kk.toString(), vv));

      bool enabled = m['enabled'] == true;

      double? fee;
      final rawFee = m['fee'];
      if (rawFee is num) {
        fee = rawFee.toDouble();
      } else if (rawFee != null) {
        fee = double.tryParse(rawFee.toString());
      }

      final accessMode = (m['access_mode'] ?? 'lifetime')
          .toString()
          .trim()
          .toLowerCase();

      int? durationMonths;
      final rawDuration = m['access_duration_months'];
      if (rawDuration is int) {
        durationMonths = rawDuration;
      } else if (rawDuration is num) {
        durationMonths = rawDuration.toInt();
      } else if (rawDuration != null) {
        durationMonths = int.tryParse(rawDuration.toString());
      }

      out[k] = _DeliveryConfigLite(
        key: k,
        enabled: enabled,
        fee: fee,
        accessMode: accessMode,
        accessDurationMonths: durationMonths,
        promoCodes: PromoCode.parseMap(m['promo_codes']),
      );
    });

    return out;
  }

  List<EnrollDeliveryOption> toEnrollOptions() {
    final orderedKeys = ['inclass', 'live', 'recorded', 'online'];
    final out = <EnrollDeliveryOption>[];

    for (final key in orderedKeys) {
      final cfg = deliveryConfigs[key];
      if (cfg == null || !cfg.enabled) continue;

      switch (key) {
        case 'inclass':
          out.add(
            EnrollDeliveryOption(
              key: 'inclass',
              label: 'In-Class',
              shortLabelEn: 'Physical lessons at our branch',
              shortLabelAr: 'دروس حضورية',
              fee: cfg.fee,
              accessMode: cfg.accessMode,
              accessDurationMonths: cfg.accessDurationMonths,
              enabled: cfg.enabled,
              promoCodes: cfg.promoCodes,
            ),
          );
          break;
        case 'live':
          out.add(
            EnrollDeliveryOption(
              key: 'live',
              label: 'Private',
              shortLabelEn: 'One-to-one fixed schedule',
              shortLabelAr: 'حصص فردية بجدول ثابت',
              fee: cfg.fee,
              accessMode: cfg.accessMode,
              accessDurationMonths: cfg.accessDurationMonths,
              enabled: cfg.enabled,
              promoCodes: cfg.promoCodes,
            ),
          );
          break;
        case 'recorded':
          out.add(
            EnrollDeliveryOption(
              key: 'recorded',
              label: 'Recorded',
              shortLabelEn: 'Self-study videos and materials',
              shortLabelAr: 'دراسة ذاتية بفيديوهات ومواد',
              fee: cfg.fee,
              accessMode: cfg.accessMode,
              accessDurationMonths: cfg.accessDurationMonths,
              enabled: cfg.enabled,
              promoCodes: cfg.promoCodes,
            ),
          );
          break;
        case 'online':
          out.add(
            EnrollDeliveryOption(
              key: 'online',
              label: 'Flexible',
              shortLabelEn: 'Group live classes, flexible booking',
              shortLabelAr: 'حصص جماعية مباشرة بمرونة في الحجز',
              fee: cfg.fee,
              accessMode: cfg.accessMode,
              accessDurationMonths: cfg.accessDurationMonths,
              enabled: cfg.enabled,
              promoCodes: cfg.promoCodes,
            ),
          );
          break;
      }
    }

    return out;
  }

  String feeRangeLabel() {
    final options = toEnrollOptions();
    final fees = options
        .map((o) => o.fee)
        .whereType<double>()
        .where((f) => f > 0)
        .toList();
    if (fees.isEmpty) return '';
    fees.sort();

    String fmt(double v) {
      final rounded = v.round();
      return rounded.toString();
    }

    final min = fees.first;
    final max = fees.last;
    if ((max - min).abs() < 0.0001) {
      return 'From ${fmt(min)}';
    }
    return 'From ${fmt(min)} to ${fmt(max)}';
  }

  static int? _parseInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString());
  }

  static String _fixUrl(String url) {
    var u = url.trim();
    if (u.isEmpty) return u;
    if (u.startsWith('//')) u = 'https:$u';
    if (u.startsWith('www.')) u = 'https://$u';
    if (u.startsWith('http://')) u = 'https://${u.substring('http://'.length)}';
    final uri = Uri.tryParse(u);
    if (uri == null) return '';
    if (uri.scheme != 'https' && uri.scheme != 'http') return '';
    if (uri.host.trim().isEmpty) return '';
    return uri.toString();
  }

  factory _CourseLite.fromMap(String id, Map<dynamic, dynamic> raw) {
    final m = raw.map((k, v) => MapEntry(k.toString(), v));

    String pickString(List<String> keys) {
      for (final k in keys) {
        final v = m[k];
        if (v != null && v.toString().trim().isNotEmpty) return v.toString();
      }
      return '';
    }

    return _CourseLite(
      id: id,
      title: pickString(['title']),
      thumb: _fixUrl(
        pickString(['thumbnail', 'thumb', 'image', 'thumbnailUrl']),
      ),
      shortDesc: pickString(['short_description', 'shortDesc']),
      longDesc: pickString(['long_description', 'longDesc']),
      content: pickString(['content', 'what_you_will_learn']),
      duration: pickString(['duration']),
      level: pickString(['level']),
      language: pickString(['language']),
      deliveryOptions: _parseList(
        m['delivery_options'] ?? m['deliveryOptions'],
      ),
      deliveryOptionRaw: pickString(['delivery_option', 'deliveryOption']),
      deliveryConfigs: _parseDeliveryConfigs(m['delivery_configs']),
      instructors: _parseInstructors(
        m['instructors_map'] ??
            m['instructors'] ??
            m['teacher'] ??
            m['teachers'],
      ),
      requirements: pickString(['requirement', 'requirements']),
      tags: _parseList(m['tags']),
      status: pickString(['status']),
      category: pickString(['category']).trim().isEmpty
          ? 'Other'
          : pickString(['category']).trim(),
      orderIndex: _parseInt(m['order_index']),
      updatedAt: _parseInt(
        m['updatedAt'] ?? m['updated_at'] ?? m['updatedAtMs'],
      ),
    );
  }
}

List<_CourseLite> _parseCoursesLite(dynamic data) {
  if (data == null) return [];
  if (data is! Map) return [];

  final out = <_CourseLite>[];

  data.forEach((key, value) {
    if (key == null || value == null) return;
    if (value is Map) {
      out.add(_CourseLite.fromMap(key.toString(), value));
    }
  });

  out.sort((a, b) {
    final ao = a.orderIndex ?? (1 << 30);
    final bo = b.orderIndex ?? (1 << 30);
    final c = ao.compareTo(bo);
    if (c != 0) return c;
    return (b.updatedAt ?? 0).compareTo(a.updatedAt ?? 0);
  });

  return out;
}

class _DeliveryConfigLite {
  const _DeliveryConfigLite({
    required this.key,
    required this.enabled,
    required this.fee,
    required this.accessMode,
    required this.accessDurationMonths,
    required this.promoCodes,
  });

  final String key;
  final bool enabled;
  final double? fee;
  final String accessMode;
  final int? accessDurationMonths;
  final Map<String, PromoCode> promoCodes;
}

class _InstructorLite {
  const _InstructorLite({required this.uid, required this.name});

  final String uid;
  final String name;
}

class _CoursesByCategory extends StatelessWidget {
  const _CoursesByCategory();

  Future<void> _openCourseDetails(
    BuildContext context,
    _CourseLite course,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => _CourseDetailsSheet(course: course),
    );
  }

  Future<void> _showCategoryCourses(
    BuildContext context, {
    required String category,
    required List<_CourseLite> courses,
  }) async {
    if (courses.isEmpty) return;

    final pageController = PageController(viewportFraction: 0.84);
    int currentIndex = 0;
    Timer? autoSlideTimer;
    bool autoStarted = false;

    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: true,
        builder: (dialogContext) {
          return StatefulBuilder(
            builder: (dialogContext, setDialogState) {
              if (!autoStarted && courses.length > 1) {
                autoStarted = true;
                autoSlideTimer = Timer.periodic(const Duration(seconds: 3), (
                  _,
                ) {
                  if (!pageController.hasClients) return;
                  final next = (currentIndex + 1) % courses.length;
                  pageController.animateToPage(
                    next,
                    duration: const Duration(milliseconds: 420),
                    curve: Curves.easeInOut,
                  );
                });
              }

              return Dialog(
                backgroundColor: Colors.transparent,
                insetPadding: const EdgeInsets.symmetric(horizontal: 14),
                child: Container(
                  constraints: const BoxConstraints(
                    maxWidth: 560,
                    maxHeight: 560,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: Brand.uiBorder),
                  ),
                  padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        category,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: Brand.primaryBlue,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Swipe courses, then open details',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Brand.mainText.withValues(alpha: 0.72),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Expanded(
                        child: PageView.builder(
                          controller: pageController,
                          itemCount: courses.length,
                          onPageChanged: (i) =>
                              setDialogState(() => currentIndex = i),
                          itemBuilder: (_, i) {
                            final c = courses[i];
                            return AnimatedContainer(
                              duration: const Duration(milliseconds: 220),
                              margin: EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: i == currentIndex ? 2 : 12,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(18),
                                border: Border.all(
                                  color: i == currentIndex
                                      ? Brand.actionOrange.withValues(
                                          alpha: 0.35,
                                        )
                                      : Brand.uiBorder,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.06),
                                    blurRadius: 12,
                                    offset: const Offset(0, 7),
                                  ),
                                ],
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Expanded(
                                    child: ClipRRect(
                                      borderRadius: const BorderRadius.vertical(
                                        top: Radius.circular(18),
                                      ),
                                      child: c.thumb.trim().isNotEmpty
                                          ? Image.network(
                                              c.thumb,
                                              fit: BoxFit.cover,
                                              errorBuilder: (_, _, _) =>
                                                  Container(
                                                    color: Brand.appBg,
                                                    alignment: Alignment.center,
                                                    child: const Icon(
                                                      Icons.school_rounded,
                                                      size: 28,
                                                      color: Brand.primaryBlue,
                                                    ),
                                                  ),
                                            )
                                          : Container(
                                              color: Brand.appBg,
                                              alignment: Alignment.center,
                                              child: const Icon(
                                                Icons.school_rounded,
                                                size: 28,
                                                color: Brand.primaryBlue,
                                              ),
                                            ),
                                    ),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.all(12),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          c.title.isEmpty
                                              ? '(Untitled course)'
                                              : c.title,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: Brand.primaryBlue,
                                            fontWeight: FontWeight.w900,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          c.duration.trim().isEmpty
                                              ? 'Ready for enrollment'
                                              : c.duration,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: Brand.mainText.withValues(
                                              alpha: 0.72,
                                            ),
                                            fontWeight: FontWeight.w700,
                                            fontSize: 12,
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        if (c.feeRangeLabel().isNotEmpty) ...[
                                          Text(
                                            c.feeRangeLabel(),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              color: Brand.actionOrange,
                                              fontWeight: FontWeight.w900,
                                              fontSize: 12,
                                            ),
                                          ),
                                          const SizedBox(height: 8),
                                        ],
                                        SizedBox(
                                          width: double.infinity,
                                          child: OutlinedButton.icon(
                                            style: OutlinedButton.styleFrom(
                                              foregroundColor:
                                                  Brand.primaryBlue,
                                              side: const BorderSide(
                                                color: Brand.primaryBlue,
                                              ),
                                              shape: RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.circular(12),
                                              ),
                                            ),
                                            onPressed: () async {
                                              Navigator.of(dialogContext).pop();
                                              await _openCourseDetails(
                                                context,
                                                c,
                                              );
                                            },
                                            icon: const Icon(
                                              Icons.info_outline_rounded,
                                            ),
                                            label: const Text(
                                              'Details | التفاصيل',
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 8),
                      Center(
                        child: Wrap(
                          spacing: 6,
                          children: List.generate(courses.length, (i) {
                            final active = i == currentIndex;
                            return AnimatedContainer(
                              duration: const Duration(milliseconds: 180),
                              width: active ? 18 : 7,
                              height: 7,
                              decoration: BoxDecoration(
                                color: active
                                    ? Brand.actionOrange
                                    : Brand.uiBorder,
                                borderRadius: BorderRadius.circular(99),
                              ),
                            );
                          }),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      );
    } finally {
      autoSlideTimer?.cancel();
      pageController.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ref = FirebaseDatabase.instance.ref('courses');

    return StreamBuilder<DatabaseEvent>(
      stream: ref.onValue,
      builder: (context, snap) {
        if (snap.hasError) {
          return const CardShell(child: Text('Could not load courses.'));
        }
        if (!snap.hasData) {
          return const CardShell(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 10),
              child: Center(child: YbsBusyLogo()),
            ),
          );
        }

        final raw = snap.data!.snapshot.value;
        final items = _parseCoursesLite(raw);
        final published = items
            .where((c) => c.status.toLowerCase().trim() == 'published')
            .toList();

        if (published.isEmpty) {
          return const CardShell(
            child: Text('No courses available right now.'),
          );
        }

        final Map<String, List<_CourseLite>> grouped = {};
        for (final c in published) {
          final cat = (c.category.trim().isEmpty) ? 'Other' : c.category.trim();
          grouped.putIfAbsent(cat, () => []);
          grouped[cat]!.add(c);
        }

        final cats = grouped.keys.toList()..sort();

        return Column(
          children: [
            for (int i = 0; i < cats.length; i++) ...[
              _CategoryGridCard(
                title: cats[i],
                courses: grouped[cats[i]] ?? const <_CourseLite>[],
                onTap: () => _showCategoryCourses(
                  context,
                  category: cats[i],
                  courses: grouped[cats[i]] ?? const <_CourseLite>[],
                ),
                onOpenCourse: (course) => _openCourseDetails(context, course),
              ),
              if (i != cats.length - 1) const SizedBox(height: 10),
            ],
          ],
        );
      },
    );
  }
}

class _CategoryGridCard extends StatefulWidget {
  const _CategoryGridCard({
    required this.title,
    required this.courses,
    required this.onTap,
    required this.onOpenCourse,
  });

  final String title;
  final List<_CourseLite> courses;
  final VoidCallback onTap;
  final void Function(_CourseLite course) onOpenCourse;

  @override
  State<_CategoryGridCard> createState() => _CategoryGridCardState();
}

class _CategoryGridCardState extends State<_CategoryGridCard> {
  static final Map<String, Color> _thumbColorCache = <String, Color>{};

  Color? _adaptiveColor;
  bool _loadingColor = false;

  @override
  void initState() {
    super.initState();
    _loadAdaptiveColor();
  }

  @override
  void didUpdateWidget(covariant _CategoryGridCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.courses != widget.courses) {
      _loadAdaptiveColor();
    }
  }

  Future<void> _loadAdaptiveColor() async {
    if (kIsWeb) {
      if (mounted) setState(() => _adaptiveColor = null);
      return;
    }
    if (_loadingColor) return;
    _loadingColor = true;

    try {
      final thumbs = widget.courses
          .map((c) => c.thumb.trim())
          .where((u) => u.isNotEmpty)
          .take(3)
          .toList();

      if (thumbs.isEmpty) {
        if (mounted) setState(() => _adaptiveColor = null);
        return;
      }

      final colors = <Color>[];
      for (final url in thumbs) {
        final fromCache = _thumbColorCache[url];
        if (fromCache != null) {
          colors.add(fromCache);
          continue;
        }

        final c = await _extractDominantColor(url);
        if (c != null) {
          _thumbColorCache[url] = c;
          colors.add(c);
        }
      }

      if (colors.isEmpty) {
        if (mounted) setState(() => _adaptiveColor = null);
        return;
      }

      final mixed = _mixColors(colors);
      if (!mounted) return;
      setState(() => _adaptiveColor = mixed);
    } finally {
      _loadingColor = false;
    }
  }

  Color _mixColors(List<Color> colors) {
    var r = 0.0;
    var g = 0.0;
    var b = 0.0;
    for (final c in colors) {
      r += c.r;
      g += c.g;
      b += c.b;
    }
    final n = colors.length.toDouble();
    return Color.from(
      alpha: 1,
      red: (r / n).clamp(0, 1),
      green: (g / n).clamp(0, 1),
      blue: (b / n).clamp(0, 1),
    );
  }

  Color _softened(Color c) {
    final hsl = HSLColor.fromColor(c);
    final softened = hsl
        .withSaturation((hsl.saturation * 0.6).clamp(0.22, 0.55))
        .withLightness((hsl.lightness * 0.86 + 0.14).clamp(0.58, 0.82));
    return softened.toColor();
  }

  Color _onColor(Color bg) {
    return ThemeData.estimateBrightnessForColor(bg) == Brightness.dark
        ? Colors.white
        : Brand.primaryBlue;
  }

  Color _adaptiveActionColor(Color c) {
    final hsl = HSLColor.fromColor(c);
    return hsl
        .withSaturation((hsl.saturation * 0.75).clamp(0.35, 0.82))
        .withLightness(0.32)
        .toColor();
  }

  Future<Color?> _extractDominantColor(String url) async {
    final imageProvider = NetworkImage(url);
    final stream = imageProvider.resolve(const ImageConfiguration());
    final completer = Completer<ImageInfo>();

    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        if (!completer.isCompleted) completer.complete(info);
      },
      onError: (error, stackTrace) {
        if (!completer.isCompleted) completer.completeError(error, stackTrace);
      },
    );
    stream.addListener(listener);

    try {
      final info = await completer.future.timeout(const Duration(seconds: 3));
      final image = info.image;
      final byteData = await image.toByteData(format: ImageByteFormat.rawRgba);
      if (byteData == null) return null;

      final bytes = byteData.buffer.asUint8List();
      final width = image.width;
      final height = image.height;
      if (width <= 0 || height <= 0) return null;

      final stepX = (width / 24).floor().clamp(1, width);
      final stepY = (height / 24).floor().clamp(1, height);

      var r = 0;
      var g = 0;
      var b = 0;
      var count = 0;

      for (var y = 0; y < height; y += stepY) {
        for (var x = 0; x < width; x += stepX) {
          final i = (y * width + x) * 4;
          if (i + 3 >= bytes.length) continue;
          final a = bytes[i + 3];
          if (a < 128) continue;
          final rr = bytes[i];
          final gg = bytes[i + 1];
          final bb = bytes[i + 2];
          final maxCh = math.max(rr, math.max(gg, bb));
          final minCh = math.min(rr, math.min(gg, bb));
          final sat = maxCh == 0 ? 0.0 : (maxCh - minCh) / maxCh;
          if (sat < 0.08) continue;

          r += rr;
          g += gg;
          b += bb;
          count++;
        }
      }

      if (count == 0) return null;
      return Color.fromRGBO(r ~/ count, g ~/ count, b ~/ count, 1);
    } catch (_) {
      return null;
    } finally {
      stream.removeListener(listener);
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final compact = width < 390;
    final cardW = compact ? 146.0 : 158.0;
    final thumbH = compact ? 80.0 : 92.0;
    final topTone = _adaptiveColor == null ? null : _softened(_adaptiveColor!);
    final chipBg = topTone == null
        ? Brand.primaryBlue.withValues(alpha: 0.10)
        : topTone.withValues(alpha: 0.34);
    final chipFg = topTone == null ? Brand.primaryBlue : _onColor(topTone);
    final actionTone = topTone == null
        ? Brand.primaryBlue
        : _adaptiveActionColor(topTone);

    return Material(
      color: Colors.transparent,
      child: Ink(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Brand.uiBorder),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: topTone == null
                ? [Colors.white, Brand.appBg.withValues(alpha: 0.88)]
                : [
                    topTone.withValues(alpha: 0.38),
                    topTone.withValues(alpha: 0.18),
                    Colors.white,
                  ],
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 10,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        padding: EdgeInsets.all(compact ? 10 : 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: compact ? 30 : 32,
                  height: compact ? 30 : 32,
                  decoration: BoxDecoration(
                    color: chipBg,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.category_rounded, color: chipFg, size: 18),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${widget.title} (${widget.courses.length})',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: Brand.primaryBlue,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: widget.onTap,
                  style: TextButton.styleFrom(foregroundColor: actionTone),
                  child: const Text('View all'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: compact ? 124 : 132,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: widget.courses.length,
                separatorBuilder: (_, ignoredSeparator) =>
                    const SizedBox(width: 8),
                itemBuilder: (_, i) {
                  final c = widget.courses[i];
                  return SizedBox(
                    width: cardW,
                    child: Material(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => widget.onOpenCourse(c),
                        child: Ink(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Brand.uiBorder),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              ClipRRect(
                                borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(11),
                                ),
                                child: SizedBox(
                                  height: thumbH,
                                  child: c.thumb.trim().isNotEmpty
                                      ? _FastNetworkThumb(
                                          url: c.thumb,
                                          fit: BoxFit.cover,
                                        )
                                      : Container(
                                          color: Brand.appBg,
                                          alignment: Alignment.center,
                                          child: const Icon(
                                            Icons.school_rounded,
                                            color: Brand.primaryBlue,
                                          ),
                                        ),
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.fromLTRB(8, 5, 8, 4),
                                child: Text(
                                  c.title.trim().isEmpty
                                      ? '(Untitled course)'
                                      : c.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                    color: Brand.primaryBlue,
                                    height: 1.15,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PrettyChip extends StatelessWidget {
  const _PrettyChip({this.icon, required this.label});

  final IconData? icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Brand.appBg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Brand.uiBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: Brand.primaryBlue),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: Brand.primaryBlue,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CourseDetailsSheet extends StatefulWidget {
  const _CourseDetailsSheet({required this.course});
  final _CourseLite course;

  @override
  State<_CourseDetailsSheet> createState() => _CourseDetailsSheetState();
}

class _CourseDetailsSheetState extends State<_CourseDetailsSheet> {
  final _formKey = GlobalKey<FormState>();
  final fullNameC = TextEditingController();
  final phoneC = TextEditingController();
  final dobC = TextEditingController();
  final emailC = TextEditingController();
  final promoC = TextEditingController();

  late final List<EnrollDeliveryOption> deliveryOptions;
  late final PageController _deliveryPageController;
  String? selectedDeliveryKey;
  int _currentDeliveryIndex = 0;
  String? _gender;
  String _privateStudyMode = 'online';
  bool saving = false;
  AppliedPromo? _appliedPromo;
  String? _promoMessage;
  bool _promoError = false;

  _CourseLite get course => widget.course;

  @override
  void initState() {
    super.initState();
    deliveryOptions = _dedupeNormalizedOptions(
      course
          .toEnrollOptions()
          .map((e) => e.normalized())
          .where((e) => e.enabled)
          .toList(),
    );

    if (deliveryOptions.isNotEmpty) {
      final firstSelectable = deliveryOptions
          .cast<EnrollDeliveryOption?>()
          .firstWhere(
            (e) => e?.isSelectable == true,
            orElse: () => deliveryOptions.first,
          );
      selectedDeliveryKey = firstSelectable?.key;
      _currentDeliveryIndex = deliveryOptions.indexWhere(
        (e) => e.key == selectedDeliveryKey,
      );
      if (_currentDeliveryIndex < 0) _currentDeliveryIndex = 0;
    }

    _deliveryPageController = PageController(
      viewportFraction: 0.82,
      initialPage: _currentDeliveryIndex,
    );
  }

  @override
  void dispose() {
    _deliveryPageController.dispose();
    fullNameC.dispose();
    phoneC.dispose();
    dobC.dispose();
    emailC.dispose();
    promoC.dispose();
    super.dispose();
  }

  void _clearPromo() {
    promoC.clear();
    _appliedPromo = null;
    _promoMessage = null;
    _promoError = false;
  }

  void _confirmPromo() {
    final selected = _selectedOption;
    final baseFee = selected?.fee ?? 0;
    final code = PromoCode.normalize(promoC.text);

    if (selected == null || baseFee <= 0) {
      setState(() {
        _appliedPromo = null;
        _promoMessage = 'Choose a priced study type first.';
        _promoError = true;
      });
      return;
    }

    if (code.isEmpty) {
      setState(() {
        _appliedPromo = null;
        _promoMessage = 'Enter a promo code first.';
        _promoError = true;
      });
      return;
    }

    final promo = selected.promoCodes[code];
    final discount = promo?.discountFor(baseFee) ?? 0;
    if (promo == null || !promo.enabled || discount <= 0) {
      setState(() {
        _appliedPromo = null;
        _promoMessage = 'Promo code is not valid for this study type.';
        _promoError = true;
      });
      return;
    }

    setState(() {
      promoC.text = code;
      _appliedPromo = AppliedPromo(
        promo: promo,
        originalFee: baseFee,
        discountAmount: discount,
      );
      _promoMessage = 'Promo code applied.';
      _promoError = false;
    });
  }

  double _effectiveFee(EnrollDeliveryOption option) {
    final applied = _appliedPromo;
    if (applied != null &&
        applied.promo.code == PromoCode.normalize(promoC.text)) {
      return applied.finalFee;
    }
    return option.fee ?? 0;
  }

  List<EnrollDeliveryOption> _dedupeNormalizedOptions(
    List<EnrollDeliveryOption> input,
  ) {
    final byKey = <String, EnrollDeliveryOption>{};
    for (final item in input) {
      final key = normalizeDeliveryKey(item.key);
      final existing = byKey[key];
      if (existing == null) {
        byKey[key] = item;
        continue;
      }

      final existingFee = existing.fee ?? 0;
      final newFee = item.fee ?? 0;
      if (newFee > existingFee || (!existing.enabled && item.enabled)) {
        byKey[key] = item;
      }
    }

    const preferredOrder = ['flexible', 'inclass', 'private', 'recorded'];
    final out = byKey.values.toList();
    out.sort(
      (a, b) => preferredOrder
          .indexOf(a.key)
          .compareTo(preferredOrder.indexOf(b.key)),
    );
    return out;
  }

  EnrollDeliveryOption? get _selectedOption {
    final key = selectedDeliveryKey;
    if (key == null) return null;
    for (final option in deliveryOptions) {
      if (option.key == key) return option;
    }
    return null;
  }

  String _formatDuration(Duration d) {
    if (d <= Duration.zero) return '0m';
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60);
    if (hours <= 0) return '${minutes}m';
    return '${hours}h ${minutes}m';
  }

  String _accessSummary(EnrollDeliveryOption option) {
    if (option.accessMode == 'duration') {
      final m = option.accessDurationMonths;
      if (m != null && m > 0) {
        return 'Access expires $m month${m == 1 ? '' : 's'} after enrollment.';
      }
    }
    return 'Lifetime access.';
  }

  Future<void> _pickDob() async {
    FocusScope.of(context).unfocus();
    final now = DateTime.now();
    var initial = DateTime(now.year - 14, now.month, now.day);
    final parts = dobC.text.trim().split('-');
    if (parts.length == 3) {
      final y = int.tryParse(parts[0]);
      final m = int.tryParse(parts[1]);
      final d = int.tryParse(parts[2]);
      if (y != null && m != null && d != null) initial = DateTime(y, m, d);
    }

    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(1950),
      lastDate: now,
      helpText: 'Date of birth',
    );
    if (picked == null) return;

    String two(int n) => n.toString().padLeft(2, '0');
    setState(() {
      dobC.text = '${picked.year}-${two(picked.month)}-${two(picked.day)}';
    });
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();

    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (saving) return;

    final selected = _selectedOption;
    if (selected == null || !selected.enabled) {
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('Please choose a study type.')),
      );
      return;
    }

    if (selected.requiresStudyMode &&
        normalizeStudyMode(_privateStudyMode).isEmpty) {
      AppToast.fromSnackBar(
        context,
        const SnackBar(
          content: Text('Please choose Online or In-Class for Private.'),
        ),
      );
      return;
    }

    final can = await EnrollLimiter.canEnrollNow(course.id);
    if (!can) {
      final rem = await EnrollLimiter.remaining(course.id);
      if (!mounted) return;
      AppToast.fromSnackBar(
        context,
        SnackBar(
          content: Text(
            'Too many attempts. Please wait ${_formatDuration(rem)} and try again.',
          ),
        ),
      );
      return;
    }

    setState(() => saving = true);

    try {
      final ref = FirebaseDatabase.instance.ref('subscriptions').push();
      final studyMode = selected.requiresStudyMode
          ? normalizeStudyMode(_privateStudyMode)
          : '';
      final studyModeText = selected.requiresStudyMode
          ? studyModeLabel(_privateStudyMode)
          : '';
      final appliedPromo = _appliedPromo;
      final selectedFee = _effectiveFee(selected);

      await ref.set({
        'courseId': course.id,
        'courseTitle': course.title,
        'fullName': fullNameC.text.trim(),
        'phone': phoneC.text.trim(),
        'gender': (_gender ?? '').trim(),
        'dob': dobC.text.trim(),
        'dateOfBirth': dobC.text.trim(),
        'email': emailC.text.trim(),
        'delivery': selected.label,
        'paymentPlan': 'By delivery option',
        'deliveryKey': selected.key,
        'deliveryLabel': selected.label,
        'studyMode': studyMode,
        'studyModeLabel': studyModeText,
        'selectedFee': selectedFee,
        'originalFee': selected.fee,
        'discountedFee': selectedFee,
        'promoCode': appliedPromo?.promo.code,
        'promoType': appliedPromo?.promo.type,
        'promoValue': appliedPromo?.promo.value,
        'discountAmount': appliedPromo?.discountAmount,
        'accessMode': selected.accessMode,
        'accessDurationMonths': selected.accessDurationMonths,
        'accessLabel': _accessSummary(selected),
        'additionalInfo': '',
        'createdAt': ServerValue.timestamp,
      });

      await EnrollLimiter.markEnrolledNow(course.id);
      if (!mounted) return;

      await showGeneralDialog(
        context: context,
        barrierDismissible: false,
        barrierLabel: '',
        barrierColor: Colors.black54,
        pageBuilder: (ctx, anim, sec) => const EnrollmentSuccessDialog(),
      );
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      AppToast.fromSnackBar(
        context,
        SnackBar(
          content: Text(
            toHumanError(
              e,
              fallback: 'Could not complete enrollment. Try again.',
            ),
          ),
        ),
      );
      setState(() => saving = false);
    }
  }

  String _fmtDate(int ms) {
    if (ms <= 0) return '-';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  Widget _starsRow(int rating) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(5, (i) {
        return Icon(
          i < rating ? Icons.star_rounded : Icons.star_border_rounded,
          size: 17,
          color: Brand.actionOrange,
        );
      }),
    );
  }

  Widget _reviewsBlock(BuildContext context) {
    final courseId = course.id.trim();
    if (courseId.isEmpty) return const SizedBox.shrink();

    return FutureBuilder<List<CourseReviewItem>>(
      future: CourseFeedbackService.listCourseReviews(
        courseId,
        visibleOnly: true,
      ),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: LinearProgressIndicator(minHeight: 2),
          );
        }
        final items = [...snap.data!];
        items.sort((a, b) {
          final byRating = b.rating.compareTo(a.rating);
          if (byRating != 0) return byRating;
          return b.createdAt.compareTo(a.createdAt);
        });
        final total = items.length;
        final avg = total == 0
            ? 0.0
            : items.fold<int>(0, (s, x) => s + x.rating) / total;

        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: Brand.uiBorder),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    'Reviews',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w900,
                      color: Brand.primaryBlue,
                    ),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => CourseReviewsScreen(
                            courseId: courseId,
                            courseTitle: course.title,
                          ),
                        ),
                      );
                    },
                    icon: const Icon(Icons.list_alt_rounded),
                    label: const Text('Read all'),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  _starsRow((avg.round().clamp(0, 5) as num).toInt()),
                  const SizedBox(width: 8),
                  Text(
                    '${avg.toStringAsFixed(1)} / 5 • $total reviews',
                    style: TextStyle(
                      color: Brand.mainText.withValues(alpha: 0.75),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              if (items.isEmpty)
                const Text(
                  'No reviews yet for this course.',
                  style: TextStyle(fontWeight: FontWeight.w600),
                )
              else
                ...items.take(3).map((r) {
                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Brand.appBg,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            ProfileAvatar(
                              name: r.displayName,
                              photoUrl: r.photoUrl,
                              radius: 14,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '${r.firstName.isEmpty ? 'Learner' : r.firstName} (${r.abbr.isEmpty ? 'L' : r.abbr})',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                            Text(
                              _fmtDate(r.createdAt),
                              style: TextStyle(
                                color: Colors.black.withValues(alpha: 0.55),
                                fontWeight: FontWeight.w600,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        _starsRow(r.rating),
                        const SizedBox(height: 6),
                        Text(
                          r.comment,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  );
                }),
            ],
          ),
        );
      },
    );
  }

  Widget _hero() {
    if (course.thumb.trim().isEmpty) {
      return Container(
        height: 190,
        decoration: BoxDecoration(
          color: Brand.appBg,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: Brand.uiBorder),
        ),
        child: const Center(
          child: Icon(Icons.school_rounded, size: 44, color: Brand.primaryBlue),
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: Image.network(
          course.thumb,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => Container(
            color: Brand.appBg,
            child: const Center(child: Icon(Icons.image_not_supported)),
          ),
        ),
      ),
    );
  }

  Widget _rtlText(BuildContext context, String value, {double height = 1.55}) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Text(
        value,
        textAlign: TextAlign.right,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          height: height,
          color: Brand.mainText.withValues(alpha: 0.85),
        ),
      ),
    );
  }

  InputDecoration _inputDeco({
    required String label,
    required IconData icon,
    String? hint,
  }) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      prefixIcon: Icon(icon),
      filled: true,
      fillColor: Colors.white,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Brand.uiBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Brand.uiBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Brand.accentCyan, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Colors.redAccent, width: 1.2),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Colors.redAccent, width: 2),
      ),
    );
  }

  Widget _sectionTitle(IconData icon, String title) {
    return Row(
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: Brand.accentCyan.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Brand.uiBorder),
          ),
          child: Icon(icon, size: 18, color: Brand.primaryBlue),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            title,
            style: const TextStyle(
              color: Brand.primaryBlue,
              fontWeight: FontWeight.w900,
              fontSize: 15,
            ),
          ),
        ),
      ],
    );
  }

  Widget _cardShell({required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Colors.white, Brand.appBg.withValues(alpha: 0.72)],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.92)),
        boxShadow: [
          BoxShadow(
            color: Brand.primaryBlue.withValues(alpha: 0.08),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: child,
    );
  }

  Color _deliveryTone(EnrollDeliveryOption option) {
    switch (option.key) {
      case 'flexible':
        return const Color(0xFF10B981);
      case 'inclass':
        return const Color(0xFF2563EB);
      case 'private':
        return const Color(0xFF9333EA);
      case 'recorded':
        return const Color(0xFFF59E0B);
      default:
        return Brand.primaryBlue;
    }
  }

  Color _deliveryTone2(EnrollDeliveryOption option) {
    switch (option.key) {
      case 'flexible':
        return const Color(0xFF06B6D4);
      case 'inclass':
        return const Color(0xFF38BDF8);
      case 'private':
        return const Color(0xFFEC4899);
      case 'recorded':
        return const Color(0xFFF97316);
      default:
        return Brand.actionOrange;
    }
  }

  String _deliveryArabicLabel(EnrollDeliveryOption option) {
    switch (option.key) {
      case 'flexible':
        return 'مرن';
      case 'inclass':
        return 'حضوري';
      case 'private':
        return 'خاص';
      case 'recorded':
        return 'مسجل';
      default:
        return option.shortLabelAr;
    }
  }

  String _deliveryPitchAr(EnrollDeliveryOption option) {
    switch (option.key) {
      case 'flexible':
        return 'تعلم أونلاين بمرونة كاملة. اختر الحصة التي تريدها، اليوم والوقت المناسب لك، وحتى الأستاذ إذا كان متاحاً. يمكنك الدراسة حسب سرعتك: حصة واحدة أو عدة حصص في اليوم أو الأسبوع أو الشهر. تستطيع إعادة الجدولة أو الإلغاء حسب القواعد المتاحة، والانتقال إلى المستوى التالي عندما تشعر أنك جاهز.';
      case 'inclass':
        return 'انضم إلى جو القسم الحقيقي، تفاعل مع الأستاذ والزملاء، واتبع برنامجاً واضحاً يساعدك على بناء عادة تعلم قوية ومنظمة.';
      case 'private':
        return 'تعلم بطريقة خاصة ومركزة، أونلاين أو حضورياً داخل القسم. اختر الجدول الذي يناسبك، وسيتم تعيين أستاذ لمرافقتك ودعمك خطوة بخطوة. هذا الخيار مناسب لمن يريد تركيزاً أكبر، تصحيحاً مباشراً، وخطة تعلم تساعده على التقدم بسرعة وثقة أكثر من الدراسة الجماعية.';
      case 'recorded':
        return 'دروس جاهزة تشاهدها في أي وقت وبالسرعة التي تناسبك. أعد الدرس، توقف، وارجع للمحتوى كلما احتجت للمراجعة.';
      default:
        return option.explanationAr();
    }
  }

  Widget _deliveryCard(EnrollDeliveryOption option, bool selected) {
    final compact = MediaQuery.sizeOf(context).width < 390;
    final tone = _deliveryTone(option);
    final tone2 = _deliveryTone2(option);
    return GestureDetector(
      onTap: saving || !option.isSelectable
          ? null
          : () {
              final index = deliveryOptions.indexOf(option);
              setState(() {
                _currentDeliveryIndex = index;
                selectedDeliveryKey = option.key;
                _clearPromo();
              });
              _deliveryPageController.animateToPage(
                index,
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOut,
              );
            },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        margin: EdgeInsets.symmetric(horizontal: 6, vertical: selected ? 1 : 8),
        padding: EdgeInsets.all(compact ? 10 : 12),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: selected
                ? [tone, tone2]
                : [tone.withValues(alpha: 0.18), tone2.withValues(alpha: 0.10)],
          ),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? Colors.white : tone.withValues(alpha: 0.35),
            width: selected ? 2.2 : 1,
          ),
          boxShadow: [
            BoxShadow(
              color: tone.withValues(alpha: selected ? 0.28 : 0.10),
              blurRadius: selected ? 18 : 10,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              option.icon(),
              color: selected ? Colors.white : tone,
              size: compact ? 22 : 24,
            ),
            const SizedBox(height: 8),
            Text(
              option.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: selected ? Colors.white : Brand.primaryBlue,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 2),
            Directionality(
              textDirection: TextDirection.rtl,
              child: Text(
                _deliveryArabicLabel(option),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: selected
                      ? Colors.white.withValues(alpha: 0.92)
                      : Brand.mainText.withValues(alpha: 0.72),
                  fontSize: 12,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
              decoration: BoxDecoration(
                color: selected
                    ? Colors.white.withValues(alpha: 0.20)
                    : Colors.white.withValues(alpha: 0.86),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: selected
                      ? Colors.white.withValues(alpha: 0.35)
                      : tone.withValues(alpha: 0.24),
                ),
              ),
              child: Text(
                option.feeLabel(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: selected ? Colors.white : tone,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _deliveryFeatureTags(EnrollDeliveryOption option) {
    final tone = _deliveryTone(option);
    List<({IconData icon, String label})> items;
    switch (option.key) {
      case 'inclass':
        items = [
          (icon: Icons.event_rounded, label: 'جدول ثابت وواضح'),
          (icon: Icons.groups_rounded, label: 'تعلم مع مجموعة'),
          (icon: Icons.school_rounded, label: 'داخل القسم'),
        ];
        break;
      case 'flexible':
        items = [
          (icon: Icons.menu_book_rounded, label: 'اختر الحصة'),
          (icon: Icons.calendar_month_rounded, label: 'اليوم والوقت'),
          (icon: Icons.person_search_rounded, label: 'اختر الأستاذ'),
          (icon: Icons.video_call_rounded, label: 'أونلاين'),
          (icon: Icons.trending_up_rounded, label: 'انتقل للمستوى التالي'),
          (icon: Icons.event_repeat_rounded, label: 'إعادة جدولة أو إلغاء'),
        ];
        break;
      case 'private':
        items = [
          (icon: Icons.person_rounded, label: 'حصص فردية'),
          (icon: Icons.place_rounded, label: 'أونلاين أو حضوري'),
          (icon: Icons.calendar_month_rounded, label: 'جدولك الخاص'),
          (icon: Icons.support_agent_rounded, label: 'دعم مستمر'),
          (icon: Icons.flash_on_rounded, label: 'تقدم أسرع'),
        ];
        break;
      case 'recorded':
        items = [
          (icon: Icons.video_library_rounded, label: 'دورة مسجلة'),
          (icon: Icons.replay_rounded, label: 'أعد المشاهدة'),
          (icon: Icons.access_time_rounded, label: 'في أي وقت'),
        ];
        break;
      default:
        items = const [];
    }

    return items.map((item) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: tone.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: tone.withValues(alpha: 0.28)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(item.icon, size: 15, color: tone),
            const SizedBox(width: 6),
            Directionality(
              textDirection: TextDirection.rtl,
              child: Text(
                item.label,
                style: TextStyle(
                  color: Brand.mainText.withValues(alpha: 0.86),
                  fontWeight: FontWeight.w800,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      );
    }).toList();
  }

  Widget _selectedDeliverySummary(EnrollDeliveryOption option) {
    final tone = _deliveryTone(option);
    final tone2 = _deliveryTone2(option);
    final modeText = option.requiresStudyMode
        ? studyModeLabel(_privateStudyMode)
        : '';
    final modeTextAr = option.requiresStudyMode
        ? studyModeLabelAr(_privateStudyMode)
        : '';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [tone.withValues(alpha: 0.15), tone2.withValues(alpha: 0.08)],
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: tone.withValues(alpha: 0.30)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [tone, tone2]),
                  borderRadius: BorderRadius.circular(15),
                  boxShadow: [
                    BoxShadow(
                      color: tone.withValues(alpha: 0.22),
                      blurRadius: 12,
                      offset: const Offset(0, 7),
                    ),
                  ],
                ),
                child: Icon(option.icon(), color: Colors.white),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      option.label,
                      style: const TextStyle(
                        color: Brand.primaryBlue,
                        fontWeight: FontWeight.w900,
                        fontSize: 16,
                      ),
                    ),
                    Directionality(
                      textDirection: TextDirection.rtl,
                      child: Text(
                        _deliveryArabicLabel(option),
                        style: TextStyle(
                          color: Brand.mainText.withValues(alpha: 0.70),
                          fontWeight: FontWeight.w800,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.86),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: tone.withValues(alpha: 0.24)),
                ),
                child: Text(
                  _appliedPromo == null
                      ? option.feeLabel()
                      : _moneyLabel(_effectiveFee(option)),
                  style: TextStyle(color: tone, fontWeight: FontWeight.w900),
                ),
              ),
            ],
          ),
          if (modeText.isNotEmpty || modeTextAr.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              modeTextAr.isNotEmpty ? '$modeText • $modeTextAr' : modeText,
              style: const TextStyle(
                color: Brand.primaryBlue,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
          const SizedBox(height: 10),
          Directionality(
            textDirection: TextDirection.rtl,
            child: Text(
              _deliveryPitchAr(option),
              style: TextStyle(
                color: Brand.mainText.withValues(alpha: 0.86),
                fontWeight: FontWeight.w800,
                height: 1.55,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Directionality(
            textDirection: TextDirection.rtl,
            child: Text(
              option.bestForAr(),
              style: const TextStyle(
                color: Brand.primaryBlue,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _deliveryFeatureTags(option),
          ),
        ],
      ),
    );
  }

  Widget _genderPill(String value, FormFieldState<String> field) {
    final selected = field.value == value;
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: saving
            ? null
            : () {
                setState(() => _gender = value);
                field.didChange(value);
              },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 13),
          decoration: BoxDecoration(
            color: selected ? Brand.primaryBlue : Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected ? Brand.primaryBlue : Brand.uiBorder,
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            value,
            style: TextStyle(
              color: selected ? Colors.white : Brand.primaryBlue,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
      ),
    );
  }

  Widget _expandableSection({
    required IconData icon,
    required String title,
    required Widget child,
    bool initiallyExpanded = false,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Brand.uiBorder),
      ),
      child: ExpansionTile(
        initiallyExpanded: initiallyExpanded,
        tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        iconColor: Brand.primaryBlue,
        collapsedIconColor: Brand.primaryBlue,
        leading: Icon(icon, color: Brand.primaryBlue),
        title: Text(
          title,
          style: const TextStyle(
            color: Brand.primaryBlue,
            fontWeight: FontWeight.w900,
          ),
        ),
        children: [child],
      ),
    );
  }

  String _moneyLabel(double value) => '${value.toStringAsFixed(0)} DA';

  Widget _promoCodeBlock(EnrollDeliveryOption option) {
    final applied = _appliedPromo;
    final hasApplied = applied != null && !_promoError;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.86),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Brand.uiBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: promoC,
                  enabled: !saving,
                  textCapitalization: TextCapitalization.characters,
                  decoration: _inputDeco(
                    label: 'Promo code | كود الخصم',
                    icon: Icons.local_offer_rounded,
                    hint: 'CODE9',
                  ),
                  onChanged: (_) {
                    if (_appliedPromo == null && _promoMessage == null) return;
                    setState(() {
                      _appliedPromo = null;
                      _promoMessage = null;
                      _promoError = false;
                    });
                  },
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: saving ? null : _confirmPromo,
                style: FilledButton.styleFrom(
                  backgroundColor: Brand.primaryBlue,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 14,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: const Text(
                  'Confirm',
                  style: TextStyle(fontWeight: FontWeight.w900),
                ),
              ),
            ],
          ),
          if (_promoMessage != null) ...[
            const SizedBox(height: 8),
            Text(
              _promoMessage!,
              style: TextStyle(
                color: _promoError ? Colors.redAccent : const Color(0xFF059669),
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
          if (hasApplied) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _PrettyChip(
                  label:
                      'Original ${_moneyLabel(applied.originalFee)} | السعر الأصلي ${applied.originalFee.toStringAsFixed(0)} د.ج',
                  icon: Icons.payments_rounded,
                ),
                _PrettyChip(
                  label:
                      'Discount -${_moneyLabel(applied.discountAmount)} | الخصم ${applied.discountAmount.toStringAsFixed(0)} د.ج',
                  icon: Icons.discount_rounded,
                ),
                _PrettyChip(
                  label:
                      'Total ${_moneyLabel(_effectiveFee(option))} | المجموع ${_effectiveFee(option).toStringAsFixed(0)} د.ج',
                  icon: Icons.check_circle_rounded,
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selectedOption;
    final showPrivateMode = selected?.requiresStudyMode == true;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return SafeArea(
      child: AnimatedPadding(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        padding: EdgeInsets.only(bottom: bottomInset),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.92,
          child: Stack(
            children: [
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        const Color(0xFFE0F7FA).withValues(alpha: 0.80),
                        Colors.white,
                        const Color(0xFFFFF3E0).withValues(alpha: 0.80),
                      ],
                    ),
                  ),
                ),
              ),
              Positioned(
                top: -42,
                right: -30,
                child: _LearningBlob(
                  color: const Color(0xFF10B981).withValues(alpha: 0.20),
                  size: 118,
                ),
              ),
              Positioned(
                top: 190,
                left: -42,
                child: _LearningBlob(
                  color: const Color(0xFFF59E0B).withValues(alpha: 0.18),
                  size: 104,
                ),
              ),
              SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(18, 8, 18, 104),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      course.title.isEmpty ? 'Course' : course.title,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w900,
                        color: Brand.primaryBlue,
                      ),
                    ),
                    const SizedBox(height: 12),
                    _hero(),
                    const SizedBox(height: 14),
                    _cardShell(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _sectionTitle(
                            Icons.menu_book_rounded,
                            '1. Choose how you want to study',
                          ),
                          const SizedBox(height: 8),
                          if (deliveryOptions.isEmpty)
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Brand.appBg,
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(color: Brand.uiBorder),
                              ),
                              child: const Text(
                                'No study options are available for this course right now.',
                                style: TextStyle(fontWeight: FontWeight.w700),
                              ),
                            )
                          else ...[
                            SizedBox(
                              height: MediaQuery.sizeOf(context).width < 390
                                  ? 132
                                  : 144,
                              child: PageView.builder(
                                controller: _deliveryPageController,
                                itemCount: deliveryOptions.length,
                                onPageChanged: saving
                                    ? null
                                    : (index) {
                                        setState(() {
                                          _currentDeliveryIndex = index;
                                          selectedDeliveryKey =
                                              deliveryOptions[index].key;
                                          _clearPromo();
                                        });
                                      },
                                itemBuilder: (_, i) => _deliveryCard(
                                  deliveryOptions[i],
                                  i == _currentDeliveryIndex,
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: List.generate(deliveryOptions.length, (
                                i,
                              ) {
                                final active = i == _currentDeliveryIndex;
                                return AnimatedContainer(
                                  duration: const Duration(milliseconds: 180),
                                  width: active ? 20 : 8,
                                  height: 8,
                                  margin: const EdgeInsets.symmetric(
                                    horizontal: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: active
                                        ? Brand.primaryBlue
                                        : Brand.uiBorder,
                                    borderRadius: BorderRadius.circular(99),
                                  ),
                                );
                              }),
                            ),
                            const SizedBox(height: 12),
                            if (selected != null) ...[
                              _selectedDeliverySummary(selected),
                              const SizedBox(height: 10),
                              if (selected.promoCodes.isNotEmpty)
                                _promoCodeBlock(selected),
                            ],
                          ],
                        ],
                      ),
                    ),
                    if (showPrivateMode) ...[
                      const SizedBox(height: 12),
                      _cardShell(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _sectionTitle(
                              Icons.place_rounded,
                              'Private lesson mode | طريقة الحصة الخاصة',
                            ),
                            const SizedBox(height: 12),
                            DropdownButtonFormField<String>(
                              initialValue:
                                  normalizeStudyMode(_privateStudyMode).isEmpty
                                  ? 'online'
                                  : normalizeStudyMode(_privateStudyMode),
                              decoration: _inputDeco(
                                label: 'Choose mode | اختر الطريقة',
                                icon: Icons.place_rounded,
                              ),
                              items: const [
                                DropdownMenuItem(
                                  value: 'online',
                                  child: Text('Online | أونلاين'),
                                ),
                                DropdownMenuItem(
                                  value: 'inclass',
                                  child: Text('In-Class | حضوري'),
                                ),
                              ],
                              onChanged: saving
                                  ? null
                                  : (v) => setState(
                                      () => _privateStudyMode = v ?? 'online',
                                    ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    _cardShell(
                      child: Form(
                        key: _formKey,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _sectionTitle(
                              Icons.assignment_rounded,
                              '2. Enrollment details | بيانات التسجيل',
                            ),
                            const SizedBox(height: 12),
                            TextFormField(
                              controller: fullNameC,
                              textInputAction: TextInputAction.next,
                              decoration: _inputDeco(
                                label: 'Full name | الاسم الكامل',
                                icon: Icons.person_rounded,
                                hint: 'Your full name | الاسم الكامل',
                              ),
                              validator: (v) {
                                final s = (v ?? '').trim();
                                if (s.isEmpty) {
                                  return 'Please enter your full name.';
                                }
                                if (s.length < 3) {
                                  return 'Name looks too short.';
                                }
                                return null;
                              },
                            ),
                            const SizedBox(height: 10),
                            TextFormField(
                              controller: phoneC,
                              keyboardType: TextInputType.phone,
                              textInputAction: TextInputAction.next,
                              decoration: _inputDeco(
                                label: 'Phone number | رقم الهاتف',
                                icon: Icons.phone_rounded,
                                hint: 'e.g. 0550 00 00 00',
                              ),
                              validator: (v) {
                                final s = (v ?? '').trim();
                                if (s.isEmpty) {
                                  return 'Please enter your phone number.';
                                }
                                if (s.length < 8) {
                                  return 'Phone number looks too short.';
                                }
                                return null;
                              },
                            ),
                            const SizedBox(height: 10),
                            TextFormField(
                              controller: dobC,
                              readOnly: true,
                              onTap: saving ? null : _pickDob,
                              decoration: _inputDeco(
                                label: 'Date of birth | تاريخ الميلاد',
                                icon: Icons.cake_rounded,
                                hint: 'YYYY-MM-DD',
                              ),
                              validator: (v) {
                                final s = (v ?? '').trim();
                                if (s.isEmpty) {
                                  return 'Please select your date of birth.';
                                }
                                final p = s.split('-');
                                if (p.length != 3) {
                                  return 'Use format YYYY-MM-DD.';
                                }
                                final y = int.tryParse(p[0]);
                                final m = int.tryParse(p[1]);
                                final d = int.tryParse(p[2]);
                                if (y == null || m == null || d == null) {
                                  return 'Use format YYYY-MM-DD.';
                                }
                                final parsed = DateTime(y, m, d);
                                if (parsed.year != y ||
                                    parsed.month != m ||
                                    parsed.day != d) {
                                  return 'Please choose a valid date.';
                                }
                                if (parsed.isAfter(DateTime.now())) {
                                  return 'Date of birth cannot be in the future.';
                                }
                                return null;
                              },
                            ),
                            const SizedBox(height: 10),
                            FormField<String>(
                              initialValue: _gender,
                              validator: (v) {
                                if (![
                                  'Male',
                                  'Female',
                                ].contains((v ?? '').trim())) {
                                  return 'Please select your gender.';
                                }
                                return null;
                              },
                              builder: (field) {
                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Padding(
                                      padding: EdgeInsets.only(
                                        left: 4,
                                        bottom: 7,
                                      ),
                                      child: Text(
                                        'Gender | الجنس',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ),
                                    Row(
                                      children: [
                                        _genderPill('Male', field),
                                        const SizedBox(width: 10),
                                        _genderPill('Female', field),
                                      ],
                                    ),
                                    if (field.errorText != null) ...[
                                      const SizedBox(height: 6),
                                      Text(
                                        field.errorText!,
                                        style: TextStyle(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.error,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ],
                                  ],
                                );
                              },
                            ),
                            const SizedBox(height: 10),
                            TextFormField(
                              controller: emailC,
                              keyboardType: TextInputType.emailAddress,
                              textInputAction: TextInputAction.done,
                              decoration: _inputDeco(
                                label:
                                    'Email (optional) | البريد الإلكتروني (اختياري)',
                                icon: Icons.alternate_email_rounded,
                                hint: 'name@example.com',
                              ),
                              validator: (v) {
                                final s = (v ?? '').trim();
                                if (s.isEmpty) return null;
                                if (!s.contains('@') || !s.contains('.')) {
                                  return 'Please enter a valid email address.';
                                }
                                return null;
                              },
                            ),
                            const SizedBox(height: 12),
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Brand.accentCyan.withValues(alpha: 0.08),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: Brand.uiBorder),
                              ),
                              child: const Row(
                                children: [
                                  Icon(
                                    Icons.info_outline_rounded,
                                    color: Brand.primaryBlue,
                                  ),
                                  SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      'لا يوجد دفع الآن. سنقوم بالتواصل معك قريباً لتأكيد التسجيل والتفاصيل.',
                                      textDirection: TextDirection.rtl,
                                      style: TextStyle(
                                        fontWeight: FontWeight.w800,
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
                    const SizedBox(height: 12),
                    _sectionTitle(Icons.info_rounded, 'More about this course'),
                    const SizedBox(height: 8),
                    Column(
                      children: [
                        if (course.content.trim().isNotEmpty)
                          _expandableSection(
                            icon: Icons.lightbulb_rounded,
                            title: 'What you will learn | ماذا ستتعلم',
                            child: SizedBox(
                              width: double.infinity,
                              child: _rtlText(context, course.content),
                            ),
                          ),
                        if (course.content.trim().isNotEmpty)
                          const SizedBox(height: 8),
                        if (course.longDesc.trim().isNotEmpty ||
                            course.shortDesc.trim().isNotEmpty)
                          _expandableSection(
                            icon: Icons.description_rounded,
                            title: 'Description | الوصف',
                            child: SizedBox(
                              width: double.infinity,
                              child: _rtlText(
                                context,
                                course.longDesc.trim().isEmpty
                                    ? course.shortDesc
                                    : course.longDesc,
                              ),
                            ),
                          ),
                        if (course.longDesc.trim().isNotEmpty ||
                            course.shortDesc.trim().isNotEmpty)
                          const SizedBox(height: 8),
                        if (course.instructors.isNotEmpty)
                          _expandableSection(
                            icon: Icons.people_rounded,
                            title: 'Instructors',
                            child: SizedBox(
                              width: double.infinity,
                              child: Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: course.instructors
                                    .map(
                                      (teacher) =>
                                          _TeacherChip(teacher: teacher),
                                    )
                                    .toList(),
                              ),
                            ),
                          ),
                        if (course.instructors.isNotEmpty)
                          const SizedBox(height: 8),
                        _expandableSection(
                          icon: Icons.reviews_rounded,
                          title: 'Reviews',
                          child: _reviewsBlock(context),
                        ),
                        if (course.requirements.trim().isNotEmpty) ...[
                          const SizedBox(height: 8),
                          _expandableSection(
                            icon: Icons.checklist_rounded,
                            title: 'Requirements',
                            child: SizedBox(
                              width: double.infinity,
                              child: _rtlText(
                                context,
                                course.requirements,
                                height: 1.45,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: ClipRect(
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.88),
                        border: const Border(
                          top: BorderSide(color: Brand.uiBorder),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.08),
                            blurRadius: 18,
                            offset: const Offset(0, -6),
                          ),
                        ],
                      ),
                      child: SizedBox(
                        height: 52,
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: saving ? null : _submit,
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF10B981),
                            foregroundColor: Colors.white,
                            disabledBackgroundColor: const Color(
                              0xFF10B981,
                            ).withValues(alpha: 0.55),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          icon: saving
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(Icons.check_circle_rounded),
                          label: Text(
                            saving ? 'Saving...' : 'Submit enrollment',
                            style: const TextStyle(fontWeight: FontWeight.w900),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LearningBlob extends StatelessWidget {
  const _LearningBlob({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.55),
              blurRadius: 48,
              spreadRadius: 10,
            ),
          ],
        ),
      ),
    );
  }
}

class ForceUpdateGate extends StatefulWidget {
  final Widget child;
  const ForceUpdateGate({super.key, required this.child});

  @override
  State<ForceUpdateGate> createState() => _ForceUpdateGateState();
}

class _ForceUpdateGateState extends State<ForceUpdateGate> {
  String? _myVersion;
  int? _myBuild;
  bool _isAdmin = false;
  StreamSubscription<User?>? _authSub;
  DatabaseReference get _ref =>
      FirebaseDatabase.instance.ref('appConfig/forceUpdate');

  @override
  void initState() {
    super.initState();
    _loadBuildAndAdmin();

    _authSub = FirebaseAuth.instance.authStateChanges().listen((_) {
      _loadBuildAndAdmin();
    });
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }

  Future<void> _loadBuildAndAdmin() async {
    final info = await PackageInfo.fromPlatform();
    final version = info.version.trim();
    final build = int.tryParse(info.buildNumber) ?? 0;

    final uid = FirebaseAuth.instance.currentUser?.uid;
    bool isAdmin = false;

    if (uid != null && uid.isNotEmpty) {
      final adminSnap = await FirebaseDatabase.instance
          .ref('admins/$uid')
          .get();
      isAdmin = adminSnap.value == true;
    }

    if (!mounted) return;
    setState(() {
      _myVersion = version.isEmpty ? '0.0.0' : version;
      _myBuild = build;
      _isAdmin = isAdmin;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_myBuild == null || _myVersion == null) {
      return const Scaffold(body: Center(child: YbsBusyLogo()));
    }

    final platformKey = kIsWeb
        ? 'web'
        : (defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android');
    return StreamBuilder<DatabaseEvent>(
      stream: _ref.onValue,
      builder: (context, snap) {
        if (snap.hasError) return widget.child;
        if (!snap.hasData) return widget.child;

        final rootVal = snap.data!.snapshot.value;
        if (rootVal is! Map) return widget.child;

        final root = rootVal.map((k, v) => MapEntry(k.toString(), v));
        final allowAdminBypass = (root['allowAdminBypass'] == true);

        final platformVal = root[platformKey];
        if (platformVal is! Map) return widget.child;

        final m = platformVal.map((k, v) => MapEntry(k.toString(), v));

        final minBuild = _toInt(m['minBuild']) ?? 0;
        final minVersion = (m['minVersion'] ?? '').toString().trim();
        final message = (m['message'] ?? '').toString().trim();

        final storeUrl = (m['storeUrl'] ?? '').toString().trim();
        final storeWebUrl = (m['storeWebUrl'] ?? '').toString().trim();

        final requiredVersion = minVersion.isEmpty ? '0.0.0' : minVersion;

        final mustUpdate = isOlderThan(
          currentVersion: _myVersion!,
          currentBuild: _myBuild!,
          minVersion: requiredVersion,
          minBuild: minBuild,
        );

        if (mustUpdate && allowAdminBypass && _isAdmin) {
          return widget.child;
        }

        if (!mustUpdate) return widget.child;

        return UpdateRequiredScreen(
          message: message.isEmpty
              ? 'A new version is available. Please update to continue.'
              : message,
          storeUrl: storeUrl,
          storeWebUrl: storeWebUrl,
        );
      },
    );
  }

  int? _toInt(dynamic x) {
    if (x == null) return null;
    if (x is int) return x;
    if (x is num) return x.toInt();
    return int.tryParse(x.toString());
  }
}

bool isOlderThan({
  required String currentVersion,
  required int currentBuild,
  required String minVersion,
  required int minBuild,
}) {
  List<int> parse(String v) {
    return v.split('.').map((e) => int.tryParse(e.trim()) ?? 0).toList();
  }

  if (currentBuild < minBuild) return true;

  final c = parse(currentVersion);
  final m = parse(minVersion);

  while (c.length < 3) {
    c.add(0);
  }
  while (m.length < 3) {
    m.add(0);
  }

  for (int i = 0; i < 3; i++) {
    if (c[i] < m[i]) return true;
    if (c[i] > m[i]) return false;
  }

  return false;
}

class UpdateRequiredScreen extends StatelessWidget {
  final String message;
  final String storeUrl;
  final String storeWebUrl;

  const UpdateRequiredScreen({
    super.key,
    required this.message,
    required this.storeUrl,
    required this.storeWebUrl,
  });

  Future<void> _openStore(BuildContext context) async {
    Future<bool> tryLaunch(String url) async {
      if (url.trim().isEmpty) return false;
      final uri = Uri.tryParse(url.trim());
      if (uri == null) return false;
      return launchUrl(uri, mode: LaunchMode.externalApplication);
    }

    final ok1 = await tryLaunch(storeUrl);
    if (ok1) return;

    final ok2 = await tryLaunch(storeWebUrl);
    if (ok2) return;

    if (!context.mounted) return;
    AppToast.show(
      context,
      'Could not open store link.',
      type: AppToastType.error,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Brand.appBg,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: CardShell(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.system_update_rounded,
                    size: 52,
                    color: Brand.actionOrange,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Update Required',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w900,
                      color: Brand.primaryBlue,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      height: 1.4,
                      color: Brand.mainText.withValues(alpha: 0.85),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 16),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: () => _openStore(context),
                        style: FilledButton.styleFrom(
                          backgroundColor: Brand.actionOrange,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        icon: const Icon(Icons.open_in_new_rounded),
                        label: const Text('Update now'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TeacherChip extends StatelessWidget {
  const _TeacherChip({required this.teacher});

  final _InstructorLite teacher;

  static bool _isSafeUid(String uid) {
    final v = uid.trim();
    if (v.length < 8) return false;
    if (v.contains('/') ||
        v.contains('.') ||
        v.contains('#') ||
        v.contains(r'$') ||
        v.contains('[') ||
        v.contains(']')) {
      return false;
    }
    return true;
  }

  static String _normalizeUrl(String input) {
    final v = input.trim();
    if (v.isEmpty) return '';
    if (v.startsWith('//')) return 'https:$v';
    if (v.startsWith('www.')) return 'https://$v';
    return v;
  }

  static bool _isHttpUrl(String input) {
    final uri = Uri.tryParse(input.trim());
    if (uri == null) return false;
    return uri.hasScheme && (uri.scheme == 'http' || uri.scheme == 'https');
  }

  static String _urlFromUnknown(dynamic raw) {
    if (raw == null) return '';
    if (raw is String) return _normalizeUrl(raw);
    if (raw is Map) {
      final m = raw.map((k, v) => MapEntry(k.toString(), v));
      for (final key in const [
        'url',
        'photo_url',
        'downloadUrl',
        'download_url',
        'value',
        'src',
        'link',
      ]) {
        final found = m[key];
        if (found == null) continue;
        final candidate = _normalizeUrl(found.toString());
        if (candidate.isNotEmpty) return candidate;
      }
    }
    return _normalizeUrl(raw.toString());
  }

  static Future<String> _loadTeacherPhoto(String uid) async {
    if (!_isSafeUid(uid)) return '';
    final snap = await FirebaseDatabase.instance
        .ref('website/teachers/${uid.trim()}/profile')
        .get();
    final value = snap.value;
    if (value is! Map) return '';
    final profile = value.map((k, v) => MapEntry(k.toString(), v));

    final single = _urlFromUnknown(profile['profile_photo']);
    if (single.isNotEmpty && _isHttpUrl(single)) return single;

    final rawPhotos = profile['profile_photos'];
    if (rawPhotos is List) {
      for (final item in rawPhotos) {
        final photo = _urlFromUnknown(item);
        if (photo.isNotEmpty && _isHttpUrl(photo)) return photo;
      }
    } else if (rawPhotos is Map) {
      final entries = rawPhotos.entries.toList()
        ..sort((a, b) {
          final ai = int.tryParse(a.key.toString()) ?? 999999;
          final bi = int.tryParse(b.key.toString()) ?? 999999;
          return ai.compareTo(bi);
        });
      for (final entry in entries) {
        final photo = _urlFromUnknown(entry.value);
        if (photo.isNotEmpty && _isHttpUrl(photo)) return photo;
      }
    } else {
      final photo = _urlFromUnknown(rawPhotos);
      if (photo.isNotEmpty && _isHttpUrl(photo)) return photo;
    }

    return '';
  }

  static String _initials(String name) {
    final parts = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((part) => part.trim().isNotEmpty)
        .toList();
    if (parts.isEmpty) return 'T';
    final first = parts.first.characters.first.toUpperCase();
    final second = parts.length > 1
        ? parts.last.characters.first.toUpperCase()
        : '';
    return '$first$second';
  }

  void _openTeacherMedia(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) =>
          TeacherMediaSheet(teacherUid: teacher.uid, teacherName: teacher.name),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canOpen = _isSafeUid(teacher.uid);
    final initials = _initials(teacher.name.isEmpty ? 'Teacher' : teacher.name);

    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: canOpen ? () => _openTeacherMedia(context) : null,
      child: Opacity(
        opacity: canOpen ? 1 : 0.75,
        child: SizedBox(
          width: 78,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              FutureBuilder<String>(
                future: _loadTeacherPhoto(teacher.uid),
                builder: (context, snap) {
                  return Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF38BDF8), Color(0xFF10B981)],
                      ),
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: const Color(
                            0xFF10B981,
                          ).withValues(alpha: 0.18),
                          blurRadius: 12,
                          offset: const Offset(0, 7),
                        ),
                      ],
                    ),
                    child: ProfileAvatar(
                      name: initials,
                      photoUrl: snap.data ?? '',
                      radius: 28,
                      fallbackBg: Brand.primaryBlue,
                      fallbackFg: Colors.white,
                      borderColor: Colors.white,
                    ),
                  );
                },
              ),
              const SizedBox(height: 6),
              Text(
                initials,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Brand.primaryBlue,
                  fontSize: 12,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
