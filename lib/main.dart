import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'LearnerDashboard.dart';

void main() {
  runApp(const DreamEnglishAcademyApp());
}

class DreamEnglishAcademyApp extends StatelessWidget {
  const DreamEnglishAcademyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Dream English Academy',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        colorSchemeSeed: const Color(0xFF2E7AF0),
        scaffoldBackgroundColor: const Color(0xFFF6F8FF),
      ),
      home: const HomeShell(),
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
      body: SafeArea(
        // Keep screens alive; no rebuild = no re-greeting on tab switching
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
        // Soft gradient base
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color(0xFFF7FAFF),
                Color(0xFFEFF3FF),
                Color(0xFFF7F8FF),
              ],
            ),
          ),
        ),

        // Watermark logo (very light)
        Positioned.fill(
          child: IgnorePointer(
            child: Opacity(
              opacity: 0.045, // keep very subtle
              child: Center(
                child: FractionallySizedBox(
                  widthFactor: 0.78,
                  child: Image.asset(
                    'assets/images/ybs_logo.png',
                    fit: BoxFit.contain,
                  ),
                ),
              ),
            ),
          ),
        ),

        // Real content
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
        borderRadius: BorderRadius.circular(18),
        color: Colors.white.withOpacity(0.85),
        border: Border.all(color: cs.onSurface.withOpacity(0.08)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 22,
            offset: const Offset(0, 12),
          )
        ],
      ),
      child: child,
    );
  }
}

/// ===== Assistant Screen (clean UI + greeting/day + silent toggle) =====

class AssistantHome extends StatefulWidget {
  const AssistantHome({super.key});

  @override
  State<AssistantHome> createState() => _AssistantHomeState();
}

class _AssistantHomeState extends State<AssistantHome>
    with TickerProviderStateMixin {
  VoiceState state = VoiceState.idle;

  // Speech + TTS
  final stt.SpeechToText _stt = stt.SpeechToText();
  final FlutterTts _tts = FlutterTts();
  bool _sttReady = false;

  // Persisted settings
  bool silentMode = false;
  String lastGreetedDay = ''; // yyyy-mm-dd

  // UI
  String userHeard = '';
  String assistantReply = '';

  // Animations
  late final AnimationController _pulseCtrl;
  late final AnimationController _waveCtrl;

  Timer? _silenceTimer;

  @override
  void initState() {
    super.initState();

    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);

    _waveCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );

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

    // Greet ONLY once per day (and never again on tab switching)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeGreetOncePerDay();
    });
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
      setState(() => assistantReply =
      'Microphone permission denied. Enable it from settings.');
      return;
    }

    setState(() {
      userHeard = '';
      // keep greeting/last answer visible; don’t wipe the UI every time
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

    // IMPORTANT: We do NOT say "You said ..." (we only show it on screen)
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
    // No auto speaking when toggling; just change mode.
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
      // IMPORTANT: no big greeting here (we already greet once per day)
      return 'Hello! How can I help you today? You can ask about IELTS, TOEFL, schedules, levels, or fees.';
    }

    return 'I can help with IELTS, TOEFL, TESOL, schedules, levels, and general info. Please tell me what you need, or contact reception for official confirmation.';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    // Minimal status text (no clutter)
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
                color: const Color(0xFFF26B3A),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 620),
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
                          color: cs.onSurface.withOpacity(0.80),
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

                      const SizedBox(height: 14),
                      Text(
                        status,
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: cs.onSurface.withOpacity(0.80),
                        ),
                      ),
                      const SizedBox(height: 14),

                      // Only show "You said" after user speaks
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

                      // Show assistant message if available (includes daily greeting)
                      if (assistantReply.trim().isNotEmpty) ...[
                        CardShell(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Reception',
                                style: Theme.of(context)
                                    .textTheme
                                    .labelLarge
                                    ?.copyWith(fontWeight: FontWeight.w900),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                assistantReply,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodyMedium
                                    ?.copyWith(height: 1.35),
                              ),
                              const SizedBox(height: 10),
                              Row(
                                children: [
                                  FilledButton.icon(
                                    onPressed: silentMode
                                        ? null
                                        : () async {
                                      if (assistantReply.isNotEmpty) {
                                        await _speak(assistantReply);
                                      }
                                    },
                                    icon: const Icon(Icons.volume_up_rounded),
                                    label: const Text('Speak'),
                                  ),
                                  const SizedBox(width: 10),
                                  OutlinedButton.icon(
                                    onPressed: () async {
                                      await _tts.stop();
                                      if (!mounted) return;
                                      _setVoiceState(VoiceState.idle);
                                    },
                                    icon: const Icon(Icons.stop_rounded),
                                    label: const Text('Stop'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],

                      // Small utility row (clean)
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

        return SizedBox(
          width: 280,
          height: 280,
          child: Stack(
            alignment: Alignment.center,
            children: [
              _GlowRing(
                size: orbSize + 92,
                opacity: glow * 0.25,
                blur: 60,
                color: (state == VoiceState.listening)
                    ? const Color(0xFFF26B3A) // orange
                    : const Color(0xFF0B2A4A), // blue
              ),
              _GlowRing(
                size: orbSize + 46,
                opacity: glow * 0.42,
                blur: 34,
                color: (state == VoiceState.listening)
                    ? const Color(0xFFF26B3A)
                    : const Color(0xFF0B2A4A),
              ),

              if (state == VoiceState.speaking)
                _WaveRings(
                  t: waveCtrl.value,
                  baseSize: orbSize + 6,
                  color: const Color(0xFFF26B3A),
                ),

              // TODO: When you send your logo, we’ll replace this icon with your logo image
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
                        (state == VoiceState.listening)
                            ? const Color(0xFFF26B3A).withOpacity(0.95) // brand orange
                            : const Color(0xFF0B2A4A).withOpacity(0.95), // brand blue
                        (state == VoiceState.listening)
                            ? const Color(0xFFF26B3A).withOpacity(0.80)
                            : const Color(0xFF0B2A4A).withOpacity(0.80),
                        Colors.white.withOpacity(0.10),
                      ],
                      stops: const [0.0, 0.62, 1.0],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: (state == VoiceState.listening)
                            ? const Color(0xFFF26B3A).withOpacity(0.35)
                            : const Color(0xFF0B2A4A).withOpacity(0.30),
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
                      color: cs.onPrimary,
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
        final opacity = (1.0 - phase).clamp(0.0, 1.0) * 0.20;

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

/// ===== Classroom Screen =====
class ClassroomHome extends StatelessWidget {
  const ClassroomHome({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return SoftBackground(
      child: Column(
        children: [
          const SimpleTopBar(title: 'Classroom'),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: CardShell(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.school_rounded, size: 46, color: cs.primary),
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
                          color: cs.onSurface.withOpacity(0.70),
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 16),

                      // ✅ Dummy enroll button
                      FilledButton.icon(
                        onPressed: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const LearnerDashboard(),
                            ),
                          );
                        },
                        icon: const Icon(Icons.how_to_reg_rounded),
                        label: const Text('Enroll (Demo)'),
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

/// ===== Stories Screen =====
class StoriesHome extends StatelessWidget {
  const StoriesHome({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return SoftBackground(
      child: Column(
        children: [
          const SimpleTopBar(title: 'Stories'),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: CardShell(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.menu_book_rounded, size: 46, color: cs.primary),
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
                          color: cs.onSurface.withOpacity(0.70),
                          height: 1.4,
                        ),
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

