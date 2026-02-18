import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:url_launcher/url_launcher.dart';

import 'admin/admin_home.dart';
import 'enroll_screen.dart';
import 'teacher/teacher_home.dart';
import 'services/fcm_service.dart';

// Keeping your imports (even if not used yet) so nothing breaks in your project
import 'learner/learner_home.dart';
import 'auth/auth_gate.dart';

final GlobalKey<ScaffoldMessengerState> messengerKey =
GlobalKey<ScaffoldMessengerState>();
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(); // uses google-services.json on Android
  await FCMService.I.init();

  runApp(const DreamEnglishAcademyApp());
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
    final colorScheme = ColorScheme.fromSeed(
      seedColor: Brand.primaryBlue,
      brightness: Brightness.light,
      primary: Brand.primaryBlue,
      secondary: Brand.actionOrange,
      tertiary: Brand.accentCyan,
      surface: Colors.white,
      background: Brand.appBg,
      onPrimary: Colors.white,
      onSecondary: Colors.white,
      onSurface: Brand.mainText,
      onBackground: Brand.mainText,
      outline: Brand.uiBorder,
      error: const Color(0xFFB00020),
    );

    return MaterialApp(
      navigatorKey: appNavigatorKey, // ✅ ADD THIS
      scaffoldMessengerKey: messengerKey,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: colorScheme,
        scaffoldBackgroundColor: Brand.appBg,
        textTheme: const TextTheme(
          bodyMedium: TextStyle(color: Brand.mainText),
          bodyLarge: TextStyle(color: Brand.mainText),
          titleLarge: TextStyle(color: Brand.mainText),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Brand.uiBorder),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Brand.uiBorder),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Brand.accentCyan, width: 2),
          ),
          contentPadding:
          const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        ),
      ),
      home: const AuthGate(
        signedOutHome: HomeShell(),
      ),
    );
  }
}

enum AppMode { assistant, classroom, stories }

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
            icon: Icon(Icons.menu_book_rounded),
            label: 'Activities',
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
                                    'Test Your Level / Certificate',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w900,
                                      fontSize: 16,
                                    ),
                                  ),
                                  SizedBox(height: 4),
                                  Text(
                                    'Tap here to open MyCert English on Play Store.',
                                    style: TextStyle(fontWeight: FontWeight.w600),
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
  final emailCtrl = TextEditingController();
  final passCtrl = TextEditingController();
  bool rememberMe = false;

  bool loading = false;
  String error = '';

  // ✅ Captcha state (still "easy", but now actually checked)
  int a = 2, b = 3;
  final captchaCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _refreshCaptcha();
    _loadRememberedEmail();
  }

  Future<void> _loadRememberedEmail() async {
    final p = await SharedPreferences.getInstance();

    final savedRemember = p.getBool('rememberMe') ?? false;
    final savedEmail = p.getString('rememberEmail') ?? '';

    if (!mounted) return;

    setState(() {
      rememberMe = savedRemember;
      if (savedRemember && savedEmail.isNotEmpty) {
        emailCtrl.text = savedEmail;
      }
    });

    // ✅ No auto-login here.
    // Firebase auto-login happens via AuthGate at app start.
  }

  Future<void> _signInWithFirebase(String email, String pass,
      {bool fromAutoLogin = false}) async {
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

      // save remember me
      final p = await SharedPreferences.getInstance();
      if (rememberMe) {
        await p.setBool('rememberMe', true);
        await p.setString('rememberEmail', email);
      } else {
        await p.setBool('rememberMe', false);
        await p.remove('rememberEmail');
      }

      // IMPORTANT: no Navigator here.
      // AuthGate will rebuild and route (Learner/Teacher/Admin/Blocked/Paused/Deleted)

      if (!mounted) return;
      setState(() => loading = false);
    } on FirebaseAuthException catch (e) {
      String msg = 'Login failed.';
      if (e.code == 'user-not-found') msg = 'No user found for that email.';
      if (e.code == 'wrong-password') msg = 'Wrong password.';
      if (e.code == 'invalid-email') msg = 'Invalid email.';
      if (e.code == 'user-disabled') msg = 'This account is disabled.';

      if (!mounted) return;
      setState(() {
        loading = false;
        error = msg;
      });
      if (!fromAutoLogin) _refreshCaptcha();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        loading = false;
        error = 'Error: $e';
      });
      if (!fromAutoLogin) _refreshCaptcha();
    }
  }

  void _refreshCaptcha() {
    // Simple deterministic random-like without extra packages
    final now = DateTime.now().millisecondsSinceEpoch;
    a = (now % 8) + 1; // 1..9
    b = ((now ~/ 7) % 8) + 1; // 1..9
    captchaCtrl.text = '';
  }

  @override
  void dispose() {
    emailCtrl.dispose();
    passCtrl.dispose();
    captchaCtrl.dispose();
    super.dispose();
  }

  bool _validate() {
    final email = emailCtrl.text.trim();
    final pass = passCtrl.text.trim();
    final cap = captchaCtrl.text.trim();

    if (email.isEmpty || !email.contains('@')) {
      setState(() => error = 'Please enter a valid email.');
      return false;
    }
    if (pass.length < 4) {
      setState(() => error = 'Password looks too short.');
      return false;
    }
    final expected = (a + b).toString();
    if (cap != expected) {
      setState(() => error = 'Captcha is incorrect. Try again.');
      _refreshCaptcha();
      return false;
    }

    setState(() => error = '');
    return true;
  }

  Future<void> _fakeLoginForNow() async {
    FocusScope.of(context).unfocus();

    // ✅ If user is clicking manually, validate captcha as before
    if (!_validate()) return;

    final email = emailCtrl.text.trim();
    final pass = passCtrl.text.trim();

    await _signInWithFirebase(email, pass, fromAutoLogin: false);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ✅ Logo + Title
        Center(
          child: Column(
            children: [
              Container(
                width: 84,
                height: 84,
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
                'Admin Login',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w900,
                  color: Brand.primaryBlue,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Sign in to manage classrooms & attendance',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Brand.mainText.withOpacity(0.70),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 18),

        // ✅ Email
        TextField(
          controller: emailCtrl,
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
            labelText: 'Email',
            prefixIcon: Icon(Icons.alternate_email_rounded),
          ),
        ),
        const SizedBox(height: 12),

        // ✅ Password
        TextField(
          controller: passCtrl,
          obscureText: true,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(
            labelText: 'Password',
            prefixIcon: Icon(Icons.lock_rounded),
          ),
          onSubmitted: (_) => loading ? null : _fakeLoginForNow(),
        ),

        const SizedBox(height: 12),

        // ✅ Captcha (better UI)
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Brand.accentCyan.withOpacity(0.08),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Brand.uiBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.verified_user_rounded,
                      color: Brand.primaryBlue, size: 18),
                  const SizedBox(width: 8),
                  Text(
                    'Quick check',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w900,
                      color: Brand.primaryBlue,
                    ),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: loading
                        ? null
                        : () {
                      setState(() => _refreshCaptcha());
                    },
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('New'),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'What is $a + $b ?',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Brand.mainText.withOpacity(0.85),
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: captchaCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  hintText: 'Answer',
                  prefixIcon: Icon(Icons.calculate_rounded),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 14),

        // ✅ Main sign in button (Action Orange)
        FilledButton.icon(
          onPressed: loading ? null : _fakeLoginForNow,
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
                strokeWidth: 2, color: Colors.white),
          )
              : const Icon(Icons.login_rounded),
          label: Text(loading ? 'Signing in...' : 'Sign in'),
        ),

        const SizedBox(height: 10),

        // ✅ Secondary button (Blue outline)
        OutlinedButton.icon(
          onPressed: loading
              ? null
              : () {
            setState(() => error = 'Google sign-in: not wired yet');
          },
          style: OutlinedButton.styleFrom(
            foregroundColor: Brand.primaryBlue,
            side: const BorderSide(color: Brand.uiBorder),
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
          icon: const Icon(Icons.g_mobiledata_rounded),
          label: const Text('Continue with Google'),
        ),

        if (error.isNotEmpty) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.error.withOpacity(0.08),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                  color:
                  Theme.of(context).colorScheme.error.withOpacity(0.35)),
            ),
            child: Row(
              children: [
                Icon(Icons.error_outline_rounded,
                    color: Theme.of(context).colorScheme.error),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    error,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
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
    return SoftBackground(
      child: Column(
        children: [
          const SimpleTopBar(title: 'Activities'),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
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
                          child: const Icon(Icons.menu_book_rounded,
                              color: Brand.primaryBlue),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Stories & Quizzes (SOON)',
                          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Next step: story levels, audio player, and quizzes.',
                          textAlign: TextAlign.center,
                          style:
                          Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Brand.mainText.withOpacity(0.75),
                            height: 1.4,
                          ),
                        ),
                      ],
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
    required this.pricePerMonth,
    required this.pricePerLevel,
    required this.accessType,
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

  final List<String> instructors;

  final double? pricePerMonth;
  final double? pricePerLevel;

  final String accessType;
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

  static double? _parseDouble(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString());
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
      thumb: _fixUrl(pickString(['thumbnail', 'thumb', 'image', 'thumbnailUrl'])),

      shortDesc: pickString(['short_description', 'shortDesc']),
      longDesc: pickString(['long_description', 'longDesc']),
      content: pickString(['content', 'what_you_will_learn']),

      duration: pickString(['duration']),
      level: pickString(['level']),
      language: pickString(['language']),

      deliveryOptions: _parseList(m['delivery_options'] ?? m['deliveryOptions']),
      deliveryOptionRaw: pickString(['delivery_option', 'deliveryOption']),

      instructors: _parseList(m['instructors'] ?? m['teacher'] ?? m['teachers']),

      pricePerMonth: _parseDouble(m['price_per_month'] ?? m['pricePerMonth']),
      pricePerLevel: _parseDouble(m['price_per_level'] ?? m['pricePerLevel']),

      accessType: pickString(['access_type', 'accessType']),
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
        debugPrint(
            'Loaded ${items.length} courses. First: ${items.isNotEmpty ? items.first.title : "none"} | pm=${items.isNotEmpty ? items.first.pricePerMonth : null} | cat=${items.isNotEmpty ? items.first.category : null}');

        final published = items
            .where((c) => c.status.toLowerCase().trim() == 'published')
            .toList();

        if (published.isEmpty) {
          return const CardShell(child: Text('No courses available right now.'));
        }

        // ✅ Group by category
        final Map<String, List<_CourseLite>> grouped = {};
        for (final c in published) {
          final cat = (c.category.trim().isEmpty) ? 'Other' : c.category.trim();
          grouped.putIfAbsent(cat, () => []);
          grouped[cat]!.add(c);
        }

        // ✅ sort category names
        final cats = grouped.keys.toList()..sort();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final cat in cats) ...[
              _CategoryRow(
                title: cat,
                courses: grouped[cat]!,
              ),
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
                  const Icon(Icons.schedule_rounded,
                      size: 16, color: Brand.primaryBlue),
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
            color: highlight ? Brand.actionOrange : Brand.uiBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 18,
            color: highlight ? Brand.actionOrange : Brand.primaryBlue,
          ),
          const SizedBox(width: 8),
          Text(
            text,
            style: TextStyle(
              fontWeight: FontWeight.w800,
              color: highlight ? Brand.actionOrange : Brand.primaryBlue,
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

  List<String> _priceLines() {
    final pm = course.pricePerMonth;
    final pl = course.pricePerLevel;

    final out = <String>[];
    if (pm != null && pm > 0) out.add('${pm.toStringAsFixed(0)} DA / month');
    if (pl != null && pl > 0) out.add('${pl.toStringAsFixed(0)} DA / level');
    return out;
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
          child: Icon(Icons.school_rounded,
              size: 44, color: Brand.primaryBlue),
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
    final prices = _priceLines();
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
                    _PrettyChip(
                        icon: Icons.bar_chart_rounded, label: course.level),
                  if (course.language.trim().isNotEmpty)
                    _PrettyChip(
                        icon: Icons.language_rounded, label: course.language),
                  if (deliveryText.isNotEmpty)
                    _PrettyChip(
                        icon: Icons.videocam_rounded, label: deliveryText),
                  if (course.duration.trim().isNotEmpty)
                    _PrettyChip(
                        icon: Icons.schedule_rounded, label: course.duration),
                ],
              ),

              const SizedBox(height: 18),

              // ✅ Info tiles (category / access / instructors)
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  if (course.category.trim().isNotEmpty)
                    _InfoTile(icon: Icons.category_rounded, text: course.category),
                  if (course.accessType.trim().isNotEmpty)
                    _InfoTile(
                        icon: Icons.lock_open_rounded, text: course.accessType),
                  if (course.instructors.isNotEmpty)
                    _InfoTile(
                        icon: Icons.people_alt_rounded,
                        text: course.instructors.join(', ')),
                ],
              ),

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

              if (prices.isNotEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Brand.actionOrange.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(18),
                    border:
                    Border.all(color: Brand.actionOrange.withOpacity(0.45)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.payments_rounded,
                          color: Brand.actionOrange),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: prices
                              .map((p) => Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text(
                              p,
                              style: const TextStyle(
                                fontWeight: FontWeight.w900,
                                color: Brand.actionOrange,
                                fontSize: 16,
                              ),
                            ),
                          ))
                              .toList(),
                        ),
                      ),
                    ],
                  ),
                ),

              if (prices.isNotEmpty) const SizedBox(height: 18),

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

              if (course.longDesc.trim().isEmpty &&
                  course.shortDesc.trim().isNotEmpty)
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
                    children: course.tags
                        .map((t) => _PrettyChip(label: t))
                        .toList(),
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
                        borderRadius: BorderRadius.circular(16)),
                  ),
                  onPressed: () async {
                    // Build delivery options exactly like before
                    List<String> deliveryOptions = [];
                    if (course.deliveryOptions.isNotEmpty) {
                      deliveryOptions = List<String>.from(course.deliveryOptions);
                    } else {
                      final raw = course.deliveryOptionRaw.trim();
                      if (raw.isNotEmpty) {
                        deliveryOptions = raw
                            .split(',')
                            .map((e) => e.trim())
                            .where((e) => e.isNotEmpty)
                            .toList();
                      }
                    }
                    if (deliveryOptions.isEmpty) deliveryOptions = ['Not specified'];

                    // ✅ Close the bottom sheet first (recommended)
                    Navigator.of(context).pop();

                    // ✅ Open the full enroll screen
                    await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => EnrollScreen(
                          courseId: course.id,
                          courseTitle: course.title,
                          pricePerMonth: course.pricePerMonth,
                          pricePerLevel: course.pricePerLevel,
                          deliveryOptions: deliveryOptions,
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
