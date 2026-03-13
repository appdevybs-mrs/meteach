import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:async';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'admin/admin_home.dart';
import 'enroll_screen.dart';
import 'teacher/teacher_home.dart';
import 'services/fcm_service.dart';
import 'learner/learner_gallery_screen.dart';
import 'learner/learner_gallery_screen.dart';
import 'firebase_options.dart';
import 'learner/learner_games_screen.dart';
import 'widgets/teacher_media_sheet.dart';
import 'shared/app_theme.dart';
// Keeping your imports (even if not used yet) so nothing breaks in your project
import 'learner/learner_home.dart';
import 'auth/auth_gate.dart';
import 'package:video_player/video_player.dart';

final GlobalKey<ScaffoldMessengerState> messengerKey =
GlobalKey<ScaffoldMessengerState>();
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  await appThemeController.loadSavedTheme();
  // ✅ 1) Catch Flutter UI errors
  FlutterError.onError = (FlutterErrorDetails details) {
    FirebaseCrashlytics.instance.recordFlutterFatalError(details);
  };

  // ✅ 2) Catch async errors (background errors)
  PlatformDispatcher.instance.onError = (error, stack) {
    FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
    return true;
  };

  // ✅ FAST START: show first screen immediately
  runApp(const DreamEnglishAcademyApp());

  // ✅ Heavy work AFTER first frame (do not block startup)
  WidgetsBinding.instance.addPostFrameCallback((_) {
    FCMService.I.init();
  });
}

/// ===== Brand Colors =====
class Brand {
  static const primaryBlue = Color(0xFF1A2B48); // #1A2B48
  static const actionOrange = Color(0xFFF98D28); // #F98D28
  static const accentCyan = Color(0xFF00D4FF); // #00D4FF
  static const mainText = Color(0xFF2D2D2D); // #2D2D2D
  static const appBg = Color(0xFFF4F7F9); // #F4F7F9
  static const uiBorder = Color(0xFFD1D9E0); // #D1D9E0
}

class DreamEnglishAcademyApp extends StatelessWidget {
  const DreamEnglishAcademyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: appThemeController,
      builder: (context, _) {
        return MaterialApp(
          navigatorKey: appNavigatorKey,
          scaffoldMessengerKey: messengerKey,
          debugShowCheckedModeBanner: false,
          theme: appThemeController.themeData,
          home: ForceUpdateGate(
            child: const AuthGate(
              signedOutHome: HomeShell(),
            ),
          ),
        );
      },
    );
  }
}

enum AppMode { assistant, classroom, stories, games }

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  AppMode mode = AppMode.assistant;

  late final List<Widget> _pages = const [
    AssistantHome(),
    ClassroomHome(),
    StoriesHome(),
    LearnerGamesScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: IndexedStack(
          index: mode.index,
          children: _pages,
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: mode.index,
        onDestinationSelected: (i) => setState(() => mode = AppMode.values[i]),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.graphic_eq_rounded),
            label: 'Courses',
          ),
          NavigationDestination(
            icon: Icon(Icons.school_rounded),
            label: 'Classroom',
          ),
          NavigationDestination(
            icon: Icon(Icons.photo_library_rounded),
            label: 'Gallery',
          ),
          NavigationDestination(
            icon: Icon(Icons.sports_esports_rounded),
            label: 'Games',
          ),
        ],
      ),
    );
  }
}

/// ===== Shared UI =====

class SoftBackground extends StatelessWidget {
  final Widget child;
  const SoftBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Soft pearl base
        Container(
          decoration: const BoxDecoration(
            color: Brand.appBg,
          ),
        ),

        // Gentle gradient wash
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Brand.appBg,
                Brand.appBg.withOpacity(0.85),
                Colors.white.withOpacity(0.55),
              ],
            ),
          ),
        ),

        // Watermark logo (very light)
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
                    errorBuilder: (_, __, ___) => const Icon(
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

  const SimpleTopBar({
    super.key,
    required this.title,
    this.right,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w900,
                color: cs.onSurface,
              ),
            ),
          ),
          if (right != null) right!,
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
        color: Colors.white.withOpacity(0.92),
        border: Border.all(color: cs.outline.withOpacity(0.85)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.06),
            blurRadius: 28,
            offset: const Offset(0, 14),
          )
        ],
      ),
      child: child,
    );
  }
}

/// =============================================================
/// ✅ AssistantHome (AI + Speech removed)
/// - No STT / TTS / permissions / voice UI
/// - Keeps the same layout and the course list logic
/// =============================================================
class AssistantHome extends StatelessWidget {
  const AssistantHome({super.key});

  static final Uri _webPlayStoreUrl = Uri.parse(
    'https://play.google.com/store/apps/details?id=com.appdevybs.mycertenglish&pcampaignid=web_share',
  );

  // ✅ This opens Play Store app directly (best on Android)
  static final Uri _marketUrl = Uri.parse(
    'market://details?id=com.appdevybs.mycertenglish',
  );

  Future<void> _openPlayStore(BuildContext context) async {
    try {
      // 1) Try Play Store app (market://)
      final okMarket = await launchUrl(
        _marketUrl,
        mode: LaunchMode.externalApplication,
      );

      if (okMarket) return;

      // 2) Fallback to https Play Store page
      final okWeb = await launchUrl(
        _webPlayStoreUrl,
        mode: LaunchMode.externalApplication,
      );

      if (!okWeb) {
        // 3) Show message if both fail
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open Play Store')),
        );
      }
    } catch (e) {
      // show error to help debugging
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Open failed: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return SoftBackground(
      child: Column(
        children: [
          const SimpleTopBar(title: 'Your Brigde School'),
          const SizedBox(height: 6),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ✅ use InkWell to guarantee tap feedback
                  Material(
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
                                color: Brand.actionOrange.withOpacity(0.12),
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
                                    ),
                                  ),
                                  SizedBox(height: 4),
                                  Text(
                                    'Tap here to open My Cert English.',
                                    style:
                                    TextStyle(fontWeight: FontWeight.w600),
                                  ),
                                ],
                              ),
                            ),
                            const Icon(
                              Icons.open_in_new_rounded,
                              color: Brand.primaryBlue,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
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

class ClassroomHome extends StatefulWidget {
  const ClassroomHome({super.key});

  @override
  State<ClassroomHome> createState() => _ClassroomHomeState();
}

class _ClassroomHomeState extends State<ClassroomHome> {
  bool showLogin = true;

  @override
  Widget build(BuildContext context) {
    return SoftBackground(
      child: Column(
        children: [
          const SimpleTopBar(title: 'Classroom'),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                  // ✅ Keyboard-safe, overflow-proof
                  child: SingleChildScrollView(
                    padding: EdgeInsets.only(
                      bottom: MediaQuery.of(context).viewInsets.bottom + 16,
                    ),
                    child: CardShell(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 220),
                        child: showLogin
                            ? ClassroomLoginSection(
                          key: const ValueKey('login'),
                          onLoggedInAdmin: () {
                            // keep your logic (AuthGate later)
                          },
                        )
                            : Column(
                          key: const ValueKey('classroomInfo'),
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 54,
                              height: 54,
                              decoration: BoxDecoration(
                                color: Brand.accentCyan.withOpacity(0.12),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: Brand.uiBorder),
                              ),
                              child: const Icon(Icons.school_rounded,
                                  color: Brand.primaryBlue),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'Classroom (Next)',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleLarge
                                  ?.copyWith(
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Next step: student/teacher login.\nTeachers mark attendance and post assignments.',
                              textAlign: TextAlign.center,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.copyWith(
                                color: Brand.mainText
                                    .withOpacity(0.75),
                                height: 1.4,
                              ),
                            ),
                            const SizedBox(height: 16),
                            FilledButton(
                              onPressed: () =>
                                  setState(() => showLogin = true),
                              style: FilledButton.styleFrom(
                                backgroundColor: Brand.primaryBlue,
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 12),
                              ),
                              child: const Text('Open Login'),
                            ),
                          ],
                        ),
                      ),
                    ),
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

class ClassroomLoginSection extends StatefulWidget {
  final VoidCallback onLoggedInAdmin;

  const ClassroomLoginSection({
    super.key,
    required this.onLoggedInAdmin,
  });

  @override
  State<ClassroomLoginSection> createState() => _ClassroomLoginSectionState();
}

class _ClassroomLoginSectionState extends State<ClassroomLoginSection> {
  // ========= Support config (fill these, otherwise buttons stay hidden) =========
  // ⚠️ Put YOUR real values here:
  // - WhatsApp format: "2136xxxxxxx" (countrycode+number, no +, no spaces) OR "0668472488"
  static const String supportWhatsAppNumber = ''; // e.g. "213668472488"
  static const String supportPhoneNumber = ''; // e.g. "0668472488"
  static const String supportEmail = ''; // e.g. "support@yourschool.com"

  // ========= Controllers =========
  final emailCtrl = TextEditingController();
  final passCtrl = TextEditingController();
  final captchaCtrl = TextEditingController();

  bool loading = false;
  bool showPass = false;

  String error = '';

  // ========= Captcha (progressive) =========
  bool showCaptcha = true; // ✅ ALWAYS required
  int a = 2, b = 3;

  // ========= Security / abuse resistance =========
  int failedAttempts = 0;
  DateTime? cooldownUntil;
  Timer? _cooldownTicker;

  // forgot-password throttle
  DateTime? _lastResetRequestAt;

  @override
  void initState() {
    super.initState();
    _refreshCaptcha();
  }

  @override
  void dispose() {
    _cooldownTicker?.cancel();
    emailCtrl.dispose();
    passCtrl.dispose();
    captchaCtrl.dispose();
    super.dispose();
  }

  void _refreshCaptcha() {
    final now = DateTime.now().millisecondsSinceEpoch;
    a = (now % 8) + 1; // 1..9
    b = ((now ~/ 7) % 8) + 1; // 1..9
    captchaCtrl.clear();
  }

  bool _isValidEmail(String email) {
    final e = email.trim();
    if (e.isEmpty) return false;
    return RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(e);
  }

  bool get _isCoolingDown {
    if (cooldownUntil == null) return false;
    return DateTime.now().isBefore(cooldownUntil!);
  }

  int get _cooldownSecondsLeft {
    if (cooldownUntil == null) return 0;
    final diff = cooldownUntil!.difference(DateTime.now()).inSeconds;
    return diff < 0 ? 0 : diff;
  }

  void _startCooldown({int seconds = 20}) {
    cooldownUntil = DateTime.now().add(Duration(seconds: seconds));
    _cooldownTicker?.cancel();

    // update UI every second while cooling down
    _cooldownTicker = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      if (!_isCoolingDown) {
        t.cancel();
        setState(() {});
      } else {
        setState(() {});
      }
    });

    setState(() {});
  }

  String _friendlyAuthMsg(FirebaseAuthException e) {
    switch (e.code) {
      case 'invalid-email':
        return 'Please enter a valid email address.';
      case 'user-disabled':
        return 'This account is disabled.';
      case 'too-many-requests':
        return 'Too many attempts. Please wait and try again.';
      case 'wrong-password':
      case 'user-not-found':
      case 'invalid-credential':
      // ✅ Security: do not reveal whether the user exists
        return 'Email or password is incorrect.';
      default:
        return 'Login failed. Please try again.';
    }
  }

  bool _validateInputs({required bool enforceCaptcha}) {
    final email = emailCtrl.text.trim().toLowerCase();
    final pass = passCtrl.text;

    if (!_isValidEmail(email)) {
      setState(() => error = 'Please enter a valid email.');
      return false;
    }
    if (pass.isEmpty) {
      setState(() => error = 'Please enter your password.');
      return false;
    }

    if (enforceCaptcha) {
      final expected = (a + b).toString();
      final cap = captchaCtrl.text.trim();
      if (cap != expected) {
        setState(() => error = 'Captcha is incorrect. Try again.');
        _refreshCaptcha();
        return false;
      }
    }

    setState(() => error = '');
    return true;
  }

  Future<void> _signInWithFirebase(String email, String pass) async {
    if (!mounted) return;

    setState(() {
      loading = true;
      error = '';
    });

    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: email,
        password: pass,
      );

      // ✅ IMPORTANT: no Navigator here (AuthGate will route)
      if (!mounted) return;
      setState(() {
        loading = false;
        failedAttempts = 0;
        // keep captcha hidden after success
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Welcome back!')),
      );
    } on FirebaseAuthException catch (e) {
      failedAttempts += 1;

      // ✅ Progressive captcha: show after first failure
      showCaptcha = true;
      _refreshCaptcha();

      // ✅ Cooldown after 3 failures
      if (failedAttempts >= 3) {
        _startCooldown(seconds: 20);
      }

      if (!mounted) return;
      setState(() {
        loading = false;
        error = _friendlyAuthMsg(e);
      });
    } catch (_) {
      failedAttempts += 1;
      showCaptcha = true;
      _refreshCaptcha();

      if (failedAttempts >= 3) {
        _startCooldown(seconds: 20);
      }

      if (!mounted) return;
      setState(() {
        loading = false;
        error = 'Login failed. Please try again.';
      });
    }
  }

  Future<void> _manualLogin() async {
    FocusScope.of(context).unfocus();
    if (loading) return;

    // cooldown check
    if (_isCoolingDown) {
      setState(() =>
      error = 'Please wait $_cooldownSecondsLeft seconds and try again.');
      return;
    }

    // Progressive captcha rule:
    // - before any failures, no captcha required
    // - after first failure, captcha required
    final requireCaptchaNow = true;

    // validate (captcha only if required)
    if (!_validateInputs(enforceCaptcha: requireCaptchaNow)) return;

    final email = emailCtrl.text.trim().toLowerCase();
    final pass = passCtrl.text;

    await _signInWithFirebase(email, pass);
  }

  Future<void> _forgotPassword() async {
    if (loading) return;

    // light throttle: 1 request per 10 seconds
    final now = DateTime.now();
    if (_lastResetRequestAt != null &&
        now.difference(_lastResetRequestAt!).inSeconds < 10) {
      setState(() => error = 'Please wait a few seconds and try again.');
      return;
    }

    final prefill = emailCtrl.text.trim();
    final ctrl = TextEditingController(text: prefill);

    final email = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset password'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Enter your email. If an account exists, we will send a reset link.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                labelText: 'Email',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: const Text('Send link'),
          ),
        ],
      ),
    );

    if (!mounted) return;
    if (email == null) return;

    final normalized = email.trim().toLowerCase();
    if (!_isValidEmail(normalized)) {
      setState(() => error = 'Please enter a valid email address.');
      return;
    }

    setState(() {
      loading = true;
      error = '';
    });

    try {
      _lastResetRequestAt = DateTime.now();

      // ✅ Security: never reveal if account exists
      await FirebaseAuth.instance.sendPasswordResetEmail(email: normalized);

      if (!mounted) return;
      setState(() => loading = false);

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'If an account exists for that email, a reset link has been sent.'),
        ),
      );
    } on FirebaseAuthException catch (_) {
      if (!mounted) return;
      setState(() => loading = false);

      // ✅ same message always
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'If an account exists for that email, a reset link has been sent.'),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => loading = false);

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'If an account exists for that email, a reset link has been sent.'),
        ),
      );
    }
  }

  Future<void> _openWhatsApp() async {
    if (supportWhatsAppNumber.trim().isEmpty) return;

    final n = supportWhatsAppNumber.trim();
    // wa.me works widely
    final uri = Uri.parse('https://wa.me/$n');
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open WhatsApp.')),
      );
    }
  }

  Future<void> _callSupport() async {
    if (supportPhoneNumber.trim().isEmpty) return;
    final uri = Uri.parse('tel:${supportPhoneNumber.trim()}');
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not start a call.')),
      );
    }
  }

  Future<void> _emailSupport() async {
    if (supportEmail.trim().isEmpty) return;
    final uri = Uri.parse(
        'mailto:${supportEmail.trim()}?subject=Support%20Request');
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open email app.')),
      );
    }
  }

  Widget _supportRow() {
    final hasWhatsApp = supportWhatsAppNumber.trim().isNotEmpty;
    final hasPhone = supportPhoneNumber.trim().isNotEmpty;
    final hasEmail = supportEmail.trim().isNotEmpty;

    if (!hasWhatsApp && !hasPhone && !hasEmail) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 6),
        Text(
          'Need help?',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontWeight: FontWeight.w800,
            color: Brand.mainText.withOpacity(0.75),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 10,
          runSpacing: 10,
          children: [
            if (hasWhatsApp)
              OutlinedButton.icon(
                onPressed: loading ? null : _openWhatsApp,
                icon: const Text('💬', style: TextStyle(fontSize: 16)),
                label: const Text('WhatsApp'),
              ),
            if (hasPhone)
              OutlinedButton.icon(
                onPressed: loading ? null : _callSupport,
                icon: const Icon(Icons.call_rounded, size: 18),
                label: const Text('Call'),
              ),
            if (hasEmail)
              OutlinedButton.icon(
                onPressed: loading ? null : _emailSupport,
                icon: const Icon(Icons.email_rounded, size: 18),
                label: const Text('Email'),
              ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ✅ Brand header (logo + title + subtitle)
        Center(
          child: Column(
            children: [
              Container(
                width: 130,
                height: 130,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: Brand.uiBorder),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.06),
                      blurRadius: 18,
                      offset: const Offset(0, 10),
                    )
                  ],
                ),
                padding: const EdgeInsets.all(12),
                child: Image.asset(
                  'assets/images/ybs_logo.png',
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const Icon(
                    Icons.school_rounded,
                    size: 44,
                    color: Brand.primaryBlue,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Sign in',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w900,
                  color: Brand.primaryBlue,
                ),
              ),
              const SizedBox(height: 6),
            ],
          ),
        ),
        const SizedBox(height: 18),

        // ✅ Email
        TextField(
          controller: emailCtrl,
          enabled: !loading,
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
            labelText: 'Email',
            prefixIcon: Icon(Icons.alternate_email_rounded),
          ),
        ),
        const SizedBox(height: 12),

        // ✅ Password (show/hide)
        TextField(
          controller: passCtrl,
          enabled: !loading,
          obscureText: !showPass,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            labelText: 'Password',
            prefixIcon: const Icon(Icons.lock_rounded),
            suffixIcon: IconButton(
              tooltip: 'Show/Hide password',
              onPressed:
              loading ? null : () => setState(() => showPass = !showPass),
              icon: Icon(showPass ? Icons.visibility_off : Icons.visibility),
            ),
          ),
          onSubmitted: (_) => loading ? null : _manualLogin(),
        ),

        const SizedBox(height: 6),

        // ✅ Forgot password (secure)
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: loading ? null : _forgotPassword,
            child: const Text('Forgot password?'),
          ),
        ),

        const SizedBox(height: 6),

        // ✅ Cooldown banner (after 3 fails)
        if (_isCoolingDown) ...[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Brand.actionOrange.withOpacity(0.10),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Brand.actionOrange.withOpacity(0.35)),
            ),
            child: Row(
              children: [
                const Icon(Icons.timer_rounded, color: Brand.actionOrange),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Too many attempts. Try again in $_cooldownSecondsLeft seconds.',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      color: Brand.actionOrange,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
        ],

        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: Brand.accentCyan.withOpacity(0.06),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Brand.uiBorder),
          ),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: Brand.primaryBlue.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Brand.uiBorder),
                ),
                child: const Icon(
                  Icons.verified_user_rounded,
                  size: 18,
                  color: Brand.primaryBlue,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '$a + $b =',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w900,
                    color: Brand.primaryBlue,
                  ),
                ),
              ),
              SizedBox(
                width: 90,
                child: TextField(
                  controller: captchaCtrl,
                  enabled: !loading,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  decoration: const InputDecoration(
                    hintText: '...',
                    isDense: true,
                    contentPadding:
                    EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'New captcha',
                onPressed: loading ? null : () => setState(_refreshCaptcha),
                icon: const Icon(Icons.refresh_rounded),
                color: Brand.primaryBlue,
              ),
            ],
          ),
        ),

        // ✅ Sign in button
        FilledButton.icon(
          onPressed: (loading || _isCoolingDown) ? null : _manualLogin,
          style: FilledButton.styleFrom(
            backgroundColor: Brand.actionOrange,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
          icon: loading
              ? const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.white,
            ),
          )
              : const Icon(Icons.login_rounded),
          label: Text(loading ? 'Signing in...' : 'Sign in'),
        ),

        // ✅ Support links row (only if configured)
        _supportRow(),

        // ✅ Error box
        if (error.isNotEmpty) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: cs.error.withOpacity(0.08),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: cs.error.withOpacity(0.35)),
            ),
            child: Row(
              children: [
                Icon(Icons.error_outline_rounded, color: cs.error),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    error,
                    style: TextStyle(
                      color: cs.error,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class StoriesHome extends StatelessWidget {
  const StoriesHome({super.key});

  @override
  Widget build(BuildContext context) {
    return const _PublicGalleryShowcase();
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
      out.add({
        'id': key.toString(),
        ...m,
      });
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
          const SimpleTopBar(title: 'Gallery'),
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
                                color: Brand.accentCyan.withOpacity(0.12),
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
                              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Public gallery teaser media will appear here.',
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                color: Brand.mainText.withOpacity(0.75),
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
                    final type = (item['type'] ?? '').toString().trim().toLowerCase();
                    final url = (item['url'] ?? '').toString().trim();
                    final uploadedByName =
                    (item['uploadedByName'] ?? '').toString().trim();
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
                            color: Brand.uiBorder.withOpacity(0.85),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.04),
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
                                Image.network(
                                  url,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => Container(
                                    color: Colors.grey.shade200,
                                    alignment: Alignment.center,
                                    child: const Icon(Icons.broken_image_outlined),
                                  ),
                                ),
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
                                    color: Colors.black.withOpacity(0.58),
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
        Container(
          color: Colors.black.withOpacity(0.18),
        ),
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
                  errorBuilder: (_, __, ___) => const Icon(
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
              color: Colors.white.withOpacity(0.08),
              border: Border(
                top: BorderSide(color: Colors.white.withOpacity(0.12)),
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
      final controller = VideoPlayerController.networkUrl(Uri.parse(widget.url));
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
        child: CircularProgressIndicator(color: Colors.white),
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

  final List<String> deliveryOptions; // delivery_options (array)
  final String deliveryOptionRaw; // delivery_option (string)

  final Map<String, _DeliveryConfigLite> deliveryConfigs;

  final List<_InstructorLite> instructors;
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

      // Case 1: stringified map like:
      // "{uid: abc123, name: John Doe}"
      final mapLike = RegExp(r'^\{\s*uid:\s*(.+?),\s*name:\s*(.+?)\s*\}$');
      final match = mapLike.firstMatch(s);
      if (match != null) {
        final uid = (match.group(1) ?? '').trim();
        final name = (match.group(2) ?? '').trim();
        addInstructor(uid, name);
        return;
      }

      // Case 2: plain teacher name
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

      // Single instructor object
      if (vm.containsKey('uid') || vm.containsKey('name')) {
        addInstructorFromMap(vm);
        return out;
      }

      // Firebase keyed structure
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

      // whole value itself is one stringified map
      if (s.startsWith('{') && s.contains('uid:') && s.contains('name:')) {
        addInstructorFromString(s);
        return out;
      }

      final parts = s.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty);
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

      final accessMode = (m['access_mode'] ?? 'lifetime').toString().trim().toLowerCase();

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
              label: 'Live',
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
              label: 'Online',
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
    // ✅ Normalize keys to String (critical)
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

      // ✅ include more variants just in case
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


      deliveryOptions: _parseList(m['delivery_options'] ?? m['deliveryOptions']),
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

      updatedAt: _parseInt(m['updatedAt'] ?? m['updated_at'] ?? m['updatedAtMs']),
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

  // optional: newest first
  out.sort((a, b) => (b.updatedAt ?? 0).compareTo(a.updatedAt ?? 0));

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
  const _InstructorLite({
    required this.uid,
    required this.name,
  });

  final String uid;
  final String name;
}

class _CoursesByCategory extends StatelessWidget {
  const _CoursesByCategory();

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
              child: Center(child: CircularProgressIndicator()),
            ),
          );
        }

        final raw = snap.data!.snapshot.value;
        final items = _parseCoursesLite(raw);
        final published = items
            .where((c) => c.status.toLowerCase().trim() == 'published')
            .toList();

        if (published.isEmpty) {
          return const CardShell(child: Text('No courses available right now.'));
        }

        final Map<String, List<_CourseLite>> grouped = {};
        for (final c in published) {
          final cat = (c.category.trim().isEmpty) ? 'Other' : c.category.trim();
          grouped.putIfAbsent(cat, () => []);
          grouped[cat]!.add(c);
        }

        final cats = grouped.keys.toList()..sort();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final cat in cats) ...[
              _CategoryRow(title: cat, courses: grouped[cat]!),
              const SizedBox(height: 18),
            ],
          ],
        );
      },
    );
  }
}

class _CategoryRow extends StatelessWidget {
  const _CategoryRow({
    required this.title,
    required this.courses,
  });

  final String title;
  final List<_CourseLite> courses;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ✅ Category title (NOT "Courses")
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w900,
              color: Brand.primaryBlue,
            ),
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 230, // ✅ smaller cards height overall
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: courses.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, i) {
              return SizedBox(
                width: 260, // ✅ card width
                child: _CourseCardMini(course: courses[i]),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _CourseCardMini extends StatelessWidget {
  const _CourseCardMini({required this.course});
  final _CourseLite course;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        backgroundColor: Colors.white,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        builder: (_) => _CourseDetailsSheet(course: course),
      ),
      child: CardShell(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min, // ✅ important
          children: [
            // Thumbnail
            ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: SizedBox(
                height: 110,
                width: double.infinity,
                child: course.thumb.trim().isNotEmpty
                    ? Image.network(
                  course.thumb,
                  fit: BoxFit.cover,
                  // ✅ stable while loading
                  loadingBuilder: (context, child, progress) {
                    if (progress == null) return child;
                    return Container(color: Brand.appBg);
                  },
                  errorBuilder: (_, __, ___) =>
                  const Center(child: Icon(Icons.image_not_supported)),
                )
                    : Container(
                  color: Brand.appBg,
                  child: const Icon(Icons.school_rounded, size: 40),
                ),
              ),
            ),
            const SizedBox(height: 10),

            // Title
            Text(
              course.title.isEmpty ? '(Untitled course)' : course.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w900,
                color: Brand.primaryBlue,
              ),
            ),

            const SizedBox(height: 8),

            // Duration only
            if (course.duration.trim().isNotEmpty)
              Row(
                children: [
                  const Icon(
                    Icons.schedule_rounded,
                    size: 16,
                    color: Brand.primaryBlue,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      course.duration,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Brand.mainText.withOpacity(0.7),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _PrettyChip extends StatelessWidget {
  const _PrettyChip({
    this.icon,
    required this.label,
    this.ellipsize = false,
  });

  final IconData? icon;
  final String label;
  final bool ellipsize;

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
        mainAxisSize: ellipsize ? MainAxisSize.max : MainAxisSize.min,
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
        color: highlight ? Brand.actionOrange.withOpacity(0.12) : Brand.appBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: highlight ? Brand.actionOrange : Brand.uiBorder,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start, // ✅
        children: [
          Icon(
            icon,
            size: 18,
            color: highlight ? Brand.actionOrange : Brand.primaryBlue,
          ),
          const SizedBox(width: 8),

          // ✅ IMPORTANT FIX
          Flexible(
            child: Text(
              text,
              maxLines: 2, // ✅ change to 3 if you want
              overflow: TextOverflow.ellipsis, // ✅ prevents overflow
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

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
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
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

class _CourseDetailsSheet extends StatelessWidget {
  const _CourseDetailsSheet({required this.course});
  final _CourseLite course;



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
          child: Icon(
            Icons.school_rounded,
            size: 44,
            color: Brand.primaryBlue,
          ),
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
          errorBuilder: (_, __, ___) => Container(
            color: Brand.appBg,
            child: const Center(child: Icon(Icons.image_not_supported)),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final deliveryText = course.deliveryOptions.isNotEmpty
        ? course.deliveryOptions.join(', ')
        : course.deliveryOptionRaw.trim();

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
              const SizedBox(height: 16),

              // ✅ Chips row (level / language / delivery)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (course.level.trim().isNotEmpty)
                    _PrettyChip(icon: Icons.bar_chart_rounded, label: course.level),
                  if (course.language.trim().isNotEmpty)
                    _PrettyChip(icon: Icons.language_rounded, label: course.language),
                  if (deliveryText.isNotEmpty)
                    _PrettyChip(icon: Icons.videocam_rounded, label: deliveryText),
                  if (course.duration.trim().isNotEmpty)
                    _PrettyChip(icon: Icons.schedule_rounded, label: course.duration),
                ],
              ),

              const SizedBox(height: 18),

              // ✅ Info tiles (category / access)
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  if (course.category.trim().isNotEmpty)
                    _InfoTile(icon: Icons.category_rounded, text: course.category),
                ],
              ),

              // ✅ Instructors as chips (separate, cleaner)
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
                      .map(
                        (teacher) => _TeacherChip(
                      teacher: teacher,
                    ),
                  )
                      .toList(),
                ),
              ],

              const SizedBox(height: 18),

              // ✅ What you will learn
              if (course.content.trim().isNotEmpty)
                _Section(
                  title: 'What you will learn',
                  child: Text(
                    course.content,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      height: 1.55,
                      color: Brand.mainText.withOpacity(0.85),
                    ),
                  ),
                ),

              const SizedBox(height: 18),



              if (course.longDesc.trim().isNotEmpty)
                _Section(
                  title: 'About this course',
                  child: Text(
                    course.longDesc,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      height: 1.55,
                      color: Brand.mainText.withOpacity(0.85),
                    ),
                  ),
                ),

              if (course.longDesc.trim().isEmpty && course.shortDesc.trim().isNotEmpty)
                _Section(
                  title: 'Overview',
                  child: Text(
                    course.shortDesc,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      height: 1.55,
                      color: Brand.mainText.withOpacity(0.85),
                    ),
                  ),
                ),

              if (course.requirements.trim().isNotEmpty)
                _Section(
                  title: 'Requirements',
                  child: Text(
                    course.requirements,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      height: 1.45,
                    ),
                  ),
                ),

              if (course.tags.isNotEmpty)
                _Section(
                  title: 'Tags',
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: course.tags.map((t) => _PrettyChip(label: t)).toList(),
                  ),
                ),

              const SizedBox(height: 8),

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
                  label: const Text('Enroll'),
                ),
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

    // ✅ if user logs in/out later, re-check admin + version/build
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
    // ✅ FAST START: if this is slow on some devices, it runs after first screen already.
    final info = await PackageInfo.fromPlatform();
    final version = info.version.trim(); // "2.0.0"
    final build = int.tryParse(info.buildNumber) ?? 0;

    final uid = FirebaseAuth.instance.currentUser?.uid;
    bool isAdmin = false;

    if (uid != null && uid.isNotEmpty) {
      final adminSnap = await FirebaseDatabase.instance.ref('admins/$uid').get();
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
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final platformKey = kIsWeb
        ? 'web'
        : (defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android');
    return StreamBuilder<DatabaseEvent>(
      stream: _ref.onValue, // ✅ listen to whole node so we can read allowAdminBypass
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

        // ✅ BYPASS RULE (admin only)
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
  // If build is below minBuild -> must update
  if (currentBuild < minBuild) return true;

  // Compare semantic versions like 2.1.0
  List<int> parse(String v) {
    return v.split('.').map((e) => int.tryParse(e.trim()) ?? 0).toList();
  }

  final c = parse(currentVersion);
  final m = parse(minVersion);

  // normalize length to 3 parts
  while (c.length < 3) c.add(0);
  while (m.length < 3) m.add(0);

  for (int i = 0; i < 3; i++) {
    if (c[i] < m[i]) return true;
    if (c[i] > m[i]) return false;
  }

  // same version -> build already checked above
  return false;
}

class UpdateRequiredScreen extends StatelessWidget {
  final String message;
  final String storeUrl; // market:// or ios scheme
  final String storeWebUrl; // https:// link fallback

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

    // 1) Try storeUrl first (best)
    final ok1 = await tryLaunch(storeUrl);
    if (ok1) return;

    // 2) fallback to web
    final ok2 = await tryLaunch(storeWebUrl);
    if (ok2) return;

    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Could not open store link.')),
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
                      color: Brand.mainText.withOpacity(0.85),
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
  const _TeacherChip({
    required this.teacher,
  });

  final _InstructorLite teacher;

  @override
  Widget build(BuildContext context) {
    final canOpen = teacher.uid.trim().isNotEmpty;

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
