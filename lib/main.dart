import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'admin/admin_home.dart';

// Keeping your imports (even if not used yet) so nothing breaks in your project
import 'LearnerDashboard.dart';
import 'auth/auth_gate.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(); // uses google-services.json on Android
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
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        ),
      ),
      home: const HomeShell(), // ✅ uses your existing tabs (Assistant / Classroom / Stories)
    );
  }
}

enum AppMode { assistant, classroom, stories }
enum VoiceState { idle, listening, speaking }
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
            label: 'Assistant',
          ),
          NavigationDestination(
            icon: Icon(Icons.school_rounded),
            label: 'Classroom',
          ),
          NavigationDestination(
            icon: Icon(Icons.menu_book_rounded),
            label: 'Stories',
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
class AssistantHome extends StatefulWidget {
  const AssistantHome({super.key});

  @override
  State<AssistantHome> createState() => _AssistantHomeState();
}

class _AssistantHomeState extends State<AssistantHome> with TickerProviderStateMixin {
  VoiceState state = VoiceState.idle;

  final stt.SpeechToText _stt = stt.SpeechToText();
  final FlutterTts _tts = FlutterTts();
  bool _sttReady = false;

  bool silentMode = false;
  String lastGreetedDay = ''; // yyyy-mm-dd

  String userHeard = '';
  String assistantReply = '';

  late final AnimationController _pulseCtrl;
  late final AnimationController _waveCtrl;

  Timer? _silenceTimer;

  @override
  void initState() {
    super.initState();

    _pulseCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))
      ..repeat(reverse: true);

    _waveCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));

    _initAll();
  }

  Future<void> _initAll() async {
    await _loadPrefs();

    await _tts.setSpeechRate(0.45);
    await _tts.setPitch(1.0);
    await _tts.setLanguage("en-US");

    _tts.setCompletionHandler(() {
      if (!mounted) return;
      _setVoiceState(VoiceState.idle);
    });

    _tts.setErrorHandler((msg) {
      if (!mounted) return;
      setState(() => assistantReply = 'TTS error: $msg');
      _setVoiceState(VoiceState.idle);
    });

    _sttReady = await _stt.initialize(
      onError: (e) {
        if (!mounted) return;
        setState(() => assistantReply = 'Speech error: ${e.errorMsg}');
        _setVoiceState(VoiceState.idle);
      },
    );

    if (!mounted) return;
    setState(() {});

    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeGreetOncePerDay());
  }

  Future<void> _loadPrefs() async {
    final p = await SharedPreferences.getInstance();
    setState(() {
      silentMode = p.getBool('silentMode') ?? false;
      lastGreetedDay = p.getString('lastGreetedDay') ?? '';
    });
  }

  Future<void> _savePrefs() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool('silentMode', silentMode);
    await p.setString('lastGreetedDay', lastGreetedDay);
  }

  String _todayKey() {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${now.year}-${two(now.month)}-${two(now.day)}';
  }

  String _timeGreeting() {
    final h = DateTime.now().hour;
    if (h < 12) return 'Good morning';
    if (h < 18) return 'Good afternoon';
    return 'Good evening';
  }

  Future<void> _maybeGreetOncePerDay() async {
    final today = _todayKey();
    if (lastGreetedDay == today) return;

    final greeting =
        '${_timeGreeting()}! Welcome to Dream English Academy. How can I help you today?';

    setState(() {
      assistantReply = greeting;
      lastGreetedDay = today;
    });
    await _savePrefs();

    if (!silentMode) {
      await _speak(greeting);
    }
  }

  @override
  void dispose() {
    _silenceTimer?.cancel();
    _pulseCtrl.dispose();
    _waveCtrl.dispose();
    _stt.stop();
    _tts.stop();
    super.dispose();
  }

  void _setVoiceState(VoiceState next) {
    setState(() => state = next);

    if (next == VoiceState.speaking) {
      _waveCtrl.repeat();
    } else {
      _waveCtrl.stop();
      _waveCtrl.reset();
    }

    if (next == VoiceState.listening) {
      _pulseCtrl.duration = const Duration(milliseconds: 900);
    } else if (next == VoiceState.idle) {
      _pulseCtrl.duration = const Duration(milliseconds: 1800);
    } else {
      _pulseCtrl.duration = const Duration(milliseconds: 1300);
    }

    if (!_pulseCtrl.isAnimating) {
      _pulseCtrl.repeat(reverse: true);
    }
  }

  double _easeInOut(double t) => t * t * (3 - 2 * t);

  Future<bool> _ensureMicPermission() async {
    final status = await Permission.microphone.request();
    return status.isGranted;
  }

  Future<void> _startListening() async {
    await _tts.stop();

    if (!_sttReady) {
      setState(() => assistantReply = 'Speech is not available on this device.');
      return;
    }

    final ok = await _ensureMicPermission();
    if (!ok) {
      setState(() => assistantReply = 'Microphone permission denied. Enable it from settings.');
      return;
    }

    setState(() {
      userHeard = '';
    });

    _setVoiceState(VoiceState.listening);

    await _stt.listen(
      listenMode: stt.ListenMode.confirmation,
      onResult: (result) {
        if (!mounted) return;
        setState(() => userHeard = result.recognizedWords);

        _silenceTimer?.cancel();
        _silenceTimer = Timer(const Duration(milliseconds: 900), () {
          _stopListeningAndAnswer();
        });
      },
    );
  }

  Future<void> _stopListeningAndAnswer() async {
    _silenceTimer?.cancel();
    await _stt.stop();

    final q = userHeard.trim();
    if (q.isEmpty) {
      _setVoiceState(VoiceState.idle);
      return;
    }

    final reply = _faqAnswer(q);
    setState(() => assistantReply = reply);

    if (!silentMode) {
      await _speak(reply);
    } else {
      _setVoiceState(VoiceState.idle);
    }
  }

  Future<void> _speak(String text) async {
    _setVoiceState(VoiceState.speaking);
    await _tts.speak(text);
  }

  Future<void> _toggleListening() async {
    if (state == VoiceState.idle) {
      await _startListening();
    } else {
      _silenceTimer?.cancel();
      await _stt.stop();
      await _tts.stop();
      _setVoiceState(VoiceState.idle);
    }
  }

  Future<void> _toggleSilent() async {
    setState(() => silentMode = !silentMode);
    await _savePrefs();
  }

  String _faqAnswer(String q) {
    final s = q.toLowerCase();
    bool hasAny(List<String> keys) => keys.any(s.contains);

    if (hasAny(['ielts'])) {
      return 'We offer IELTS preparation with speaking, writing, listening, and reading practice, plus mock tests and feedback. What is your current band and target band?';
    }
    if (hasAny(['toefl'])) {
      return 'We offer TOEFL preparation with strategies and full skill practice. Are you preparing for TOEFL iBT, and what is your target score?';
    }
    if (hasAny(['tesol'])) {
      return 'We provide TESOL guidance and training. Is your goal teaching abroad, online teaching, or improving teaching skills?';
    }
    if (hasAny(['price', 'cost', 'fee', 'fees', 'pay', 'how much'])) {
      return 'For official fees, please contact reception or check our official page. Tell me which course you want (IELTS, TOEFL, or General English) and I will guide you.';
    }
    if (hasAny(['schedule', 'time', 'timetable', 'when', 'days', 'hours'])) {
      return 'Schedules depend on your level and course type. Tell me which course you want and your preferred days, and I will guide you.';
    }
    if (hasAny(['level', 'placement', 'test', 'beginner', 'intermediate', 'advanced'])) {
      return 'We can help you choose the right level. Tell me your last exam score or your current level and I will suggest the best starting course.';
    }
    if (hasAny(['location', 'address', 'where'])) {
      return 'You can find our location on the Dream English Academy website and social pages. Tell me your city or area and I will guide you.';
    }
    if (hasAny(['hello', 'hi', 'hey'])) {
      return 'Hello! How can I help you today? You can ask about IELTS, TOEFL, schedules, levels, or fees.';
    }

    return 'I can help with IELTS, TOEFL, TESOL, schedules, levels, and general info. Please tell me what you need, or contact reception for official confirmation.';
  }
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final status = switch (state) {
      VoiceState.idle => 'Tap the orb to speak',
      VoiceState.listening => 'Listening…',
      VoiceState.speaking => 'Speaking…',
    };

    return SoftBackground(
      child: Column(
        children: [
          SimpleTopBar(
            title: 'Dream English Academy',
            right: IconButton(
              onPressed: _toggleSilent,
              tooltip: silentMode ? 'Silent: ON' : 'Silent: OFF',
              icon: Icon(
                silentMode ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                color: Brand.actionOrange,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        state == VoiceState.listening
                            ? '🎙️ Listening…'
                            : state == VoiceState.speaking
                            ? '🔊 Speaking…'
                            : '👆 Tap the orb to speak',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: cs.onSurface.withOpacity(0.85),
                        ),
                      ),
                      const SizedBox(height: 14),

                      _Orb(
                        pulseCtrl: _pulseCtrl,
                        waveCtrl: _waveCtrl,
                        state: state,
                        onTap: _toggleListening,
                        cs: cs,
                        ease: _easeInOut,
                      ),

                      const SizedBox(height: 14),
                      Text(
                        status,
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: cs.onSurface.withOpacity(0.82),
                        ),
                      ),
                      const SizedBox(height: 14),

                      if (userHeard.trim().isNotEmpty) ...[
                        CardShell(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'You said',
                                style: Theme.of(context)
                                    .textTheme
                                    .labelLarge
                                    ?.copyWith(fontWeight: FontWeight.w900),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                userHeard,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodyMedium
                                    ?.copyWith(height: 1.35),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],

                      if (assistantReply.trim().isNotEmpty) ...[
                        CardShell(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    width: 36,
                                    height: 36,
                                    decoration: BoxDecoration(
                                      color: Brand.accentCyan.withOpacity(0.10),
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(color: Brand.uiBorder),
                                    ),
                                    child: const Icon(Icons.support_agent_rounded, color: Brand.primaryBlue),
                                  ),
                                  const SizedBox(width: 10),
                                  Text(
                                    'Reception',
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelLarge
                                        ?.copyWith(fontWeight: FontWeight.w900),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              Text(
                                assistantReply,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodyMedium
                                    ?.copyWith(height: 1.35),
                              ),
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  Expanded(
                                    child: FilledButton.icon(
                                      onPressed: silentMode
                                          ? null
                                          : () async {
                                        if (assistantReply.isNotEmpty) {
                                          await _speak(assistantReply);
                                        }
                                      },
                                      style: FilledButton.styleFrom(
                                        backgroundColor: Brand.actionOrange,
                                        foregroundColor: Colors.white,
                                        padding: const EdgeInsets.symmetric(vertical: 12),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(14),
                                        ),
                                      ),
                                      icon: const Icon(Icons.volume_up_rounded),
                                      label: const Text('Speak'),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      onPressed: () async {
                                        await _tts.stop();
                                        if (!mounted) return;
                                        _setVoiceState(VoiceState.idle);
                                      },
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: Brand.primaryBlue,
                                        side: const BorderSide(color: Brand.uiBorder),
                                        padding: const EdgeInsets.symmetric(vertical: 12),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(14),
                                        ),
                                      ),
                                      icon: const Icon(Icons.stop_rounded),
                                      label: const Text('Stop'),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],

                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          TextButton.icon(
                            onPressed: () => setState(() {
                              userHeard = '';
                              assistantReply = '';
                            }),
                            icon: const Icon(Icons.delete_outline_rounded),
                            label: const Text('Clear'),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            _sttReady ? 'Voice ready' : 'Voice not ready',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: cs.onSurface.withOpacity(0.55),
                            ),
                          ),
                        ],
                      ),
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

/// Orb (fixed size so UI doesn’t jump)
class _Orb extends StatelessWidget {
  final AnimationController pulseCtrl;
  final AnimationController waveCtrl;
  final VoiceState state;
  final VoidCallback onTap;
  final ColorScheme cs;
  final double Function(double) ease;

  const _Orb({
    required this.pulseCtrl,
    required this.waveCtrl,
    required this.state,
    required this.onTap,
    required this.cs,
    required this.ease,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([pulseCtrl, waveCtrl]),
      builder: (context, _) {
        final pulse = ease(pulseCtrl.value);

        final base = 150.0;
        final orbSize = base + (pulse * 14);

        final glow = switch (state) {
          VoiceState.idle => 0.18 + pulse * 0.18,
          VoiceState.listening => 0.30 + pulse * 0.30,
          VoiceState.speaking => 0.28 + pulse * 0.25,
        };

        final isHot = state == VoiceState.listening;

        return SizedBox(
          width: 280,
          height: 280,
          child: Stack(
            alignment: Alignment.center,
            children: [
              _GlowRing(
                size: orbSize + 92,
                opacity: glow * 0.22,
                blur: 60,
                color: isHot ? Brand.actionOrange : Brand.primaryBlue,
              ),
              _GlowRing(
                size: orbSize + 46,
                opacity: glow * 0.40,
                blur: 34,
                color: isHot ? Brand.actionOrange : Brand.primaryBlue,
              ),

              if (state == VoiceState.speaking)
                _WaveRings(
                  t: waveCtrl.value,
                  baseSize: orbSize + 6,
                  color: Brand.accentCyan,
                ),

              GestureDetector(
                onTap: onTap,
                child: Container(
                  width: orbSize,
                  height: orbSize,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      center: const Alignment(-0.25, -0.35),
                      radius: 1.2,
                      colors: [
                        (isHot ? Brand.actionOrange : Brand.primaryBlue).withOpacity(0.98),
                        (isHot ? Brand.actionOrange : Brand.primaryBlue).withOpacity(0.80),
                        Colors.white.withOpacity(0.10),
                      ],
                      stops: const [0.0, 0.62, 1.0],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: (isHot ? Brand.actionOrange : Brand.primaryBlue).withOpacity(0.30),
                        blurRadius: 40,
                        spreadRadius: 4,
                      ),
                    ],
                  ),
                  child: Center(
                    child: Icon(
                      state == VoiceState.listening
                          ? Icons.mic_rounded
                          : state == VoiceState.speaking
                          ? Icons.volume_up_rounded
                          : Icons.touch_app_rounded,
                      size: 40,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
class _GlowRing extends StatelessWidget {
  final double size;
  final double opacity;
  final double blur;
  final Color color;

  const _GlowRing({
    required this.size,
    required this.opacity,
    required this.blur,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: color.withOpacity(opacity),
            blurRadius: blur,
            spreadRadius: 2,
          )
        ],
      ),
    );
  }
}

class _WaveRings extends StatelessWidget {
  final double t;
  final double baseSize;
  final Color color;

  const _WaveRings({
    required this.t,
    required this.baseSize,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: List.generate(3, (i) {
        final phase = (t + i * 0.22) % 1.0;
        final size = baseSize + (phase * 96);
        final opacity = (1.0 - phase).clamp(0.0, 1.0) * 0.22;

        return Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: color.withOpacity(opacity),
              width: 2,
            ),
          ),
        );
      }),
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
                              child: const Icon(Icons.school_rounded, color: Brand.primaryBlue),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'Classroom (Next)',
                              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Next step: student/teacher login.\nTeachers mark attendance and post assignments.',
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                color: Brand.mainText.withOpacity(0.75),
                                height: 1.4,
                              ),
                            ),
                            const SizedBox(height: 16),
                            FilledButton(
                              onPressed: () => setState(() => showLogin = true),
                              style: FilledButton.styleFrom(
                                backgroundColor: Brand.primaryBlue,
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
    _loadRememberedLoginAndAutoSignIn();
  }
  Future<void> _loadRememberedLoginAndAutoSignIn() async {
    final p = await SharedPreferences.getInstance();

    final savedRemember = p.getBool('rememberMe') ?? false;
    final savedEmail = p.getString('rememberEmail') ?? '';
    final savedPass = p.getString('rememberPass') ?? '';

    if (!mounted) return;

    setState(() {
      rememberMe = savedRemember;
      if (savedRemember && savedEmail.isNotEmpty) {
        emailCtrl.text = savedEmail;
      }
      if (savedRemember && savedPass.isNotEmpty) {
        passCtrl.text = savedPass;
      }
    });

    // ✅ Auto-login ONLY if remember me is on and credentials exist
    if (savedRemember && savedEmail.isNotEmpty && savedPass.isNotEmpty) {
      // Skip captcha for auto-login (better UX)
      await _signInWithFirebase(savedEmail, savedPass, fromAutoLogin: true);
    }
  }
  Future<void> _signInWithFirebase(String email, String pass, {bool fromAutoLogin = false}) async {
    setState(() {
      loading = true;
      error = '';
    });

    try {
      final cred = await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: email,
        password: pass,
      );

      final uid = cred.user?.uid;
      if (uid == null) throw Exception('Login failed (no user).');

      final ref = FirebaseDatabase.instance.ref('users/$uid/role');
      final snap = await ref.get();
      final role = snap.value?.toString().trim().toLowerCase();

      if (role == 'admin') {
        // ✅ Save if remember me
        if (rememberMe) {
          final p = await SharedPreferences.getInstance();
          await p.setBool('rememberMe', true);
          await p.setString('rememberEmail', email);
          await p.setString('rememberPass', pass);
        }

        if (!mounted) return;
        setState(() => loading = false);

        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const AdminHome()),
        );
        return;
      }

      await FirebaseAuth.instance.signOut();
      setState(() {
        loading = false;
        error = 'Access denied: you are not an admin.';
      });

      if (!fromAutoLogin) _refreshCaptcha();
    } on FirebaseAuthException catch (e) {
      String msg = 'Login failed.';
      if (e.code == 'user-not-found') msg = 'No user found for that email.';
      if (e.code == 'wrong-password') msg = 'Wrong password.';
      if (e.code == 'invalid-email') msg = 'Invalid email.';
      if (e.code == 'user-disabled') msg = 'This account is disabled.';

      setState(() {
        loading = false;
        error = msg;
      });

      if (!fromAutoLogin) _refreshCaptcha();
    } catch (e) {
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
    a = (now % 8) + 1;      // 1..9
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
                  const Icon(Icons.verified_user_rounded, color: Brand.primaryBlue, size: 18),
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
            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
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
              border: Border.all(color: Theme.of(context).colorScheme.error.withOpacity(0.35)),
            ),
            child: Row(
              children: [
                Icon(Icons.error_outline_rounded, color: Theme.of(context).colorScheme.error),
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
          const SimpleTopBar(title: 'Stories'),
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
                          child: const Icon(Icons.menu_book_rounded, color: Brand.primaryBlue),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Stories & Quizzes (Next)',
                          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Next step: story levels, audio player, and quizzes.',
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
              ),
            ),
          ),
        ],
      ),
    );
  }
}
