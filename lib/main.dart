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
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'enroll_screen.dart';
import 'course_reviews_screen.dart';
import 'services/fcm_service.dart';
import 'services/backend_api.dart';
import 'services/course_feedback_service.dart';
import 'services/push_client.dart';
import 'services/push_error_logger.dart';
import 'firebase_options.dart';
import 'learner/learner_games_screen.dart';
import 'learner/learner_stories_screen.dart';
import 'widgets/teacher_media_sheet.dart';
import 'shared/app_theme.dart';
import 'shared/app_feedback.dart';
import 'shared/course_join_rules.dart';
import 'shared/human_error.dart';
import 'shared/profile_avatar.dart';
import 'shared/ybs_busy_logo.dart';
import 'auth/auth_gate.dart';
import 'verify_certificate_screen.dart';
import 'package:video_player/video_player.dart';

part 'home/home_shell.part.dart';
part 'home/login.part.dart';

/// App-level snackbar access for services outside widget tree.
final GlobalKey<ScaffoldMessengerState> messengerKey =
    GlobalKey<ScaffoldMessengerState>();

/// App-level navigator access for notification deep-links.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  FlutterError.onError = (FlutterErrorDetails details) {
    FirebaseCrashlytics.instance.recordFlutterFatalError(details);
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
    return true;
  };

  runApp(const YourBridgeSchoolApp());

  WidgetsBinding.instance.addPostFrameCallback((_) {
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
          SimpleTopBar(title: 'Your Bridge School', right: _CvnVerifyButton()),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _LevelTestCard(),
                  const SizedBox(height: 18),
                  const SizedBox(height: 10),
                  const _JoinOnlineCircleEntryButton(),
                  const SizedBox(height: 18),
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
        ],
      ),
    );
  }
}

class _CvnVerifyButton extends StatelessWidget {
  const _CvnVerifyButton();

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Brand.primaryBlue.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const VerifyCertificateScreen()),
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.shield_rounded, color: Brand.primaryBlue, size: 20),
              const SizedBox(width: 6),
              Text(
                'CVN',
                style: TextStyle(
                  color: Brand.primaryBlue,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LevelTestCard extends StatelessWidget {
  _LevelTestCard();

  final Uri _webPlayStoreUrl = Uri.parse(
    'https://play.google.com/store/apps/details?id=com.appdevybs.mycertenglish&pcampaignid=web_share',
  );

  final Uri _marketUrl = Uri.parse(
    'market://details?id=com.appdevybs.mycertenglish',
  );

  Future<void> _openPlayStore(BuildContext context) async {
    try {
      final okMarket = await launchUrl(
        _marketUrl,
        mode: LaunchMode.externalApplication,
      );

      if (okMarket) return;

      final okWeb = await launchUrl(
        _webPlayStoreUrl,
        mode: LaunchMode.externalApplication,
      );

      if (!context.mounted) return;
      if (!okWeb) {
        AppToast.show(
          context,
          'Could not open Play Store',
          type: AppToastType.error,
        );
      }
    } catch (e) {
      if (!context.mounted) return;
      AppToast.show(
        context,
        toHumanError(e, fallback: 'Could not open Play Store.'),
        type: AppToastType.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => _openPlayStore(context),
        child: CardShell(
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: Brand.actionOrange.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Brand.uiBorder),
                ),
                child: const Icon(
                  Icons.workspace_premium_rounded,
                  color: Brand.actionOrange,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    Text(
                      'Test Your Level & Get Certified',
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 16,
                        color: Brand.primaryBlue,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Tap here to open My Cert English.',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: Brand.mainText,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.open_in_new_rounded, color: Brand.primaryBlue),
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
    extends State<_JoinOnlineCircleEntryButton>
    with SingleTickerProviderStateMixin {
  static const String circlesPath = 'circle';
  late final AnimationController _pulseController;
  late final Animation<double> _scaleAnimation;
  late final PageController _pageController;
  List<_OnlineCircle> _prefetchedOpenCircles = const [];
  bool _prefetching = true;
  int _activeIndex = 0;
  String _openCirclesSignature = '';

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 1.04).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _pageController = PageController(viewportFraction: 0.86);
    _pulseController.repeat(reverse: true);
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
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    return 'Starts in ${_two(h)}:${_two(m)}:${_two(s)}';
  }

  Widget _circleHeroImage({
    required _OnlineCircle circle,
    required bool isPast,
  }) {
    final imageUrl = circle.circleImageUrl.trim();

    Widget child;
    if (imageUrl.isEmpty) {
      child = Container(
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
        child: const Center(
          child: Icon(Icons.groups_rounded, color: Colors.white, size: 52),
        ),
      );
    } else {
      child = Image.network(
        imageUrl,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => Container(
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
          child: const Center(
            child: Icon(
              Icons.broken_image_outlined,
              color: Colors.white,
              size: 42,
            ),
          ),
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
                          ProfileAvatar(
                            name: teacherName,
                            photoUrl: circle.teacherProfilePhoto,
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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ProfileAvatar(
                name: teacherName,
                photoUrl: circle.teacherProfilePhoto,
                radius: 34,
                fallbackBg: Brand.primaryBlue,
                fallbackFg: Colors.white,
                borderColor: Colors.white,
              ),
              const SizedBox(height: 14),
              Text(
                circle.topic,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w900,
                  color: Brand.primaryBlue,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'with $teacherName',
                textAlign: TextAlign.center,
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
                    icon: Icons.schedule_rounded,
                    label: _formatTimeOnly(circle.timeMs),
                  ),
                  _PrettyChip(
                    icon: Icons.timer_outlined,
                    label: '${circle.durationMinutes} min',
                  ),
                  _PrettyChip(
                    icon: Icons.info_outline_rounded,
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
                      icon: Icons.calendar_today_rounded,
                      label: 'Date & time',
                      value: _formatDateTime(circle.timeMs),
                    ),
                    const SizedBox(height: 10),
                    const _DetailRow(
                      icon: Icons.access_time_filled_rounded,
                      label: 'Join rule',
                      value:
                          'Users can join from 5 minutes before start until the circle duration ends.',
                    ),
                    if (circle.description.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      _DetailRow(
                        icon: Icons.notes_rounded,
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
                      _CircleJoinStatusBanner(state: joinState, circle: circle),
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
                                Container(
                                  width: 44,
                                  height: 44,
                                  decoration: BoxDecoration(
                                    color: Brand.primaryBlue.withValues(
                                      alpha: 0.10,
                                    ),
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  child: const Icon(
                                    Icons.groups_rounded,
                                    color: Brand.primaryBlue,
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
    _pulseController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: _scaleAnimation,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: _openCirclesFullscreen,
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFFFFD54F),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: const Color(0xFFFFC107), width: 1.4),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFFFFC107).withValues(alpha: 0.35),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Row(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: const Icon(
                    Icons.groups_rounded,
                    color: Brand.primaryBlue,
                    size: 28,
                  ),
                ),
                const SizedBox(width: 14),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Join Online Meeting',
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 17,
                          color: Brand.primaryBlue,
                        ),
                      ),
                      SizedBox(height: 5),
                      Text(
                        'Tap to view circle cards and join on time.',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: Brand.primaryBlue,
                          height: 1.25,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.arrow_forward_rounded,
                    color: Brand.primaryBlue,
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
      return const _CircleJoinState(
        canJoin: false,
        message: 'This class is not open yet.',
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

class _PublicGalleryShowcase extends StatefulWidget {
  const _PublicGalleryShowcase();

  @override
  State<_PublicGalleryShowcase> createState() => _PublicGalleryShowcaseState();
}

class _PublicGalleryShowcaseState extends State<_PublicGalleryShowcase> {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  DatabaseReference _galleryRef() => _db.child('public_gallery_teasers');

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

  static String _two(int n) => n < 10 ? '0$n' : '$n';

  String _fmtDate(dynamic ts) {
    final ms = _toInt(ts);
    if (ms <= 0) return '-';

    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.year}-${_two(d.month)}-${_two(d.day)}  ${_two(d.hour)}:${_two(d.minute)}';
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
                final items = _itemsFromSnapshot(snap.data?.snapshot.value);

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

                return GridView.builder(
                  padding: const EdgeInsets.fromLTRB(18, 6, 18, 18),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                    childAspectRatio: 1,
                  ),
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    final type = (item['type'] ?? '')
                        .toString()
                        .trim()
                        .toLowerCase();
                    final url = (item['url'] ?? '').toString().trim();
                    final uploadedByName = (item['uploadedByName'] ?? '')
                        .toString()
                        .trim();
                    final createdAt = _fmtDate(item['createdAt']);

                    return InkWell(
                      borderRadius: BorderRadius.circular(20),
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => _PublicGalleryViewerScreen(
                              type: type,
                              url: url,
                              uploadedByName: uploadedByName,
                              createdAt: createdAt,
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
                                const _PublicGalleryVideoTile()
                              else
                                _FastNetworkThumb(url: url, fit: BoxFit.cover),
                              Positioned(
                                left: 10,
                                right: 10,
                                bottom: 10,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 8,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.58),
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        type == 'video'
                                            ? Icons.play_circle_fill_rounded
                                            : Icons.photo_rounded,
                                        color: Colors.white,
                                        size: 16,
                                      ),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: Text(
                                          type == 'video' ? 'Video' : 'Photo',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.w900,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _PublicGalleryVideoTile extends StatelessWidget {
  const _PublicGalleryVideoTile();

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Container(
          color: Colors.black,
          child: const Center(
            child: Icon(
              Icons.videocam_rounded,
              color: Colors.white70,
              size: 42,
            ),
          ),
        ),
        Container(color: Colors.black.withValues(alpha: 0.18)),
        const Center(
          child: Icon(
            Icons.play_circle_fill_rounded,
            color: Colors.white,
            size: 52,
          ),
        ),
      ],
    );
  }
}

class _PublicGalleryViewerScreen extends StatelessWidget {
  const _PublicGalleryViewerScreen({
    required this.type,
    required this.url,
    required this.uploadedByName,
    required this.createdAt,
  });

  final String type;
  final String url;
  final String uploadedByName;
  final String createdAt;

  @override
  Widget build(BuildContext context) {
    final isVideo = type.trim().toLowerCase() == 'video';

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(
          isVideo ? 'Video' : 'Photo',
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: isVideo
                  ? _PublicGalleryViewerVideo(url: url)
                  : InteractiveViewer(
                      minScale: 0.8,
                      maxScale: 4,
                      child: Image.network(
                        url,
                        fit: BoxFit.contain,
                        errorBuilder: (_, _, _) => const Icon(
                          Icons.broken_image_outlined,
                          color: Colors.white,
                          size: 44,
                        ),
                      ),
                    ),
            ),
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.08),
              border: Border(
                top: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isVideo ? 'Video' : 'Photo',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    fontSize: 15,
                  ),
                ),
                if (uploadedByName.trim().isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    'Uploaded by: $uploadedByName',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
                const SizedBox(height: 4),
                Text(
                  'Added: $createdAt',
                  style: const TextStyle(
                    color: Colors.white60,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
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
    final u = url.trim();
    if (u.isEmpty) return u;
    if (u.startsWith('//')) return 'https:$u';
    if (u.startsWith('www.')) return 'https://$u';
    return u;
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
  });

  final String key;
  final bool enabled;
  final double? fee;
  final String accessMode;
  final int? accessDurationMonths;
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

class _CategoryGridCard extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final compact = width < 390;
    final cardW = compact ? 146.0 : 158.0;
    final thumbH = compact ? 84.0 : 92.0;

    return Material(
      color: Colors.transparent,
      child: Ink(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Brand.uiBorder),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Colors.white, Brand.appBg.withValues(alpha: 0.88)],
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
                    color: Brand.primaryBlue.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.category_rounded,
                    color: Brand.primaryBlue,
                    size: 18,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '$title (${courses.length})',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: Brand.primaryBlue,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                TextButton(onPressed: onTap, child: const Text('View all')),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: compact ? 142 : 150,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: courses.length,
                separatorBuilder: (_, ignoredSeparator) =>
                    const SizedBox(width: 8),
                itemBuilder: (_, i) {
                  final c = courses[i];
                  return SizedBox(
                    width: cardW,
                    child: Material(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => onOpenCourse(c),
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
                                padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
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

class _InfoTile extends StatelessWidget {
  const _InfoTile({
    required this.icon,
    required this.text,
    this.highlight = false,
  });

  final IconData icon;
  final String text;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: highlight
            ? Brand.actionOrange.withValues(alpha: 0.12)
            : Brand.appBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: highlight ? Brand.actionOrange : Brand.uiBorder,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            icon,
            size: 18,
            color: highlight ? Brand.actionOrange : Brand.primaryBlue,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: highlight ? Brand.actionOrange : Brand.primaryBlue,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CourseDetailsSheet extends StatelessWidget {
  const _CourseDetailsSheet({required this.course});
  final _CourseLite course;

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

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 22),
        child: SingleChildScrollView(
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
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: Brand.primaryBlue,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  onPressed: () async {
                    final enrollOptions = course.toEnrollOptions();

                    Navigator.of(context).pop();

                    await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => EnrollScreen(
                          courseId: course.id,
                          courseTitle: course.title,
                          deliveryOptions: enrollOptions,
                        ),
                      ),
                    );
                  },
                  icon: const Icon(Icons.how_to_reg_rounded),
                  label: const Text('Course Enrollment | التسجيل في الدورة'),
                ),
              ),
              const SizedBox(height: 18),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  if (course.category.trim().isNotEmpty)
                    _InfoTile(
                      icon: Icons.category_rounded,
                      text: course.category,
                    ),
                  if (course.feeRangeLabel().trim().isNotEmpty)
                    _InfoTile(
                      icon: Icons.payments_rounded,
                      text: 'Fees: ${course.feeRangeLabel()}',
                      highlight: true,
                    ),
                ],
              ),
              const SizedBox(height: 14),
              _reviewsBlock(context),
              if (course.instructors.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  'Instructors',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w900,
                    color: Brand.primaryBlue,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: course.instructors
                      .map((teacher) => _TeacherChip(teacher: teacher))
                      .toList(),
                ),
              ],
              const SizedBox(height: 18),
              if (course.content.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'ماذا ستتعلم',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              fontWeight: FontWeight.w900,
                              color: Brand.primaryBlue,
                            ),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: _rtlText(context, course.content),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 18),
              if (course.longDesc.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'الوصف',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              fontWeight: FontWeight.w900,
                              color: Brand.primaryBlue,
                            ),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: _rtlText(context, course.longDesc),
                      ),
                    ],
                  ),
                ),
              if (course.longDesc.trim().isEmpty &&
                  course.shortDesc.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'الوصف',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              fontWeight: FontWeight.w900,
                              color: Brand.primaryBlue,
                            ),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: _rtlText(context, course.shortDesc),
                      ),
                    ],
                  ),
                ),
              if (course.requirements.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 18),
                  child: _rtlText(context, course.requirements, height: 1.45),
                ),
            ],
          ),
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
                  SizedBox(
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

  @override
  Widget build(BuildContext context) {
    final canOpen = _isSafeUid(teacher.uid);

    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: !canOpen
          ? null
          : () {
              showModalBottomSheet(
                context: context,
                isScrollControlled: true,
                showDragHandle: true,
                backgroundColor: Colors.white,
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                ),
                builder: (_) => TeacherMediaSheet(
                  teacherUid: teacher.uid,
                  teacherName: teacher.name,
                ),
              );
            },
      child: Opacity(
        opacity: canOpen ? 1 : 0.75,
        child: _PrettyChip(
          icon: Icons.person_rounded,
          label: teacher.name.isEmpty ? 'Teacher' : teacher.name,
        ),
      ),
    );
  }
}
