part of '../main.dart';

enum AppMode { home, media, jobs }

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  AppMode mode = AppMode.home;

  late final List<Widget> _pages = const [
    AssistantHome(),
    MediaHome(),
    JobsHome(),
  ];

  Future<void> _openLogin(BuildContext context) async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const LoginScreen()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: IndexedStack(index: mode.index, children: _pages),
      ),
      floatingActionButton: _PulsingLoginFab(
        onPressed: () => _openLogin(context),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: mode.index,
        onDestinationSelected: (i) => setState(() => mode = AppMode.values[i]),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_rounded), label: 'Home'),
          NavigationDestination(
            icon: Icon(Icons.perm_media_rounded),
            label: 'Media',
          ),
          NavigationDestination(
            icon: Icon(Icons.work_outline_rounded),
            label: 'Jobs',
          ),
        ],
      ),
    );
  }
}

class _PulsingLoginFab extends StatefulWidget {
  const _PulsingLoginFab({required this.onPressed});

  final VoidCallback onPressed;

  @override
  State<_PulsingLoginFab> createState() => _PulsingLoginFabState();
}

class _PulsingLoginFabState extends State<_PulsingLoginFab>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 950),
    )..repeat(reverse: true);
    _scale = Tween<double>(
      begin: 1.0,
      end: 1.06,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: _scale,
      child: FloatingActionButton.extended(
        onPressed: widget.onPressed,
        backgroundColor: Brand.actionOrange,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.login_rounded),
        label: const Text('Login'),
      ),
    );
  }
}

class MediaHome extends StatelessWidget {
  const MediaHome({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: SoftBackground(
        child: Column(
          children: [
            const SimpleTopBar(title: 'Media'),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.95),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Brand.uiBorder),
                ),
                child: const TabBar(
                  tabs: [
                    Tab(text: 'Stories'),
                    Tab(text: 'Games'),
                    Tab(text: 'Gallery'),
                  ],
                ),
              ),
            ),
            const Expanded(
              child: TabBarView(
                children: [StoriesHome(), GamesHome(), GalleryHome()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class JobsHome extends StatefulWidget {
  const JobsHome({super.key});

  @override
  State<JobsHome> createState() => _JobsHomeState();
}

class _JobsHomeState extends State<JobsHome> {
  bool _showApplyForm = false;
  final ScrollController _scrollCtrl = ScrollController();
  Timer? _descTimer;
  int _descIndex = 0;

  static const List<String> _jobDescriptions = [
    'Submit your application anytime. We review applications continuously.',
    'Envoyez votre candidature a tout moment. Nous examinons les demandes en continu.',
    'يمكنك إرسال طلب التوظيف في أي وقت، ونقوم بمراجعة الطلبات بشكل مستمر.',
  ];

  @override
  void initState() {
    super.initState();
    _descTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!mounted) return;
      setState(() => _descIndex = (_descIndex + 1) % _jobDescriptions.length);
    });
  }

  @override
  void dispose() {
    _descTimer?.cancel();
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SoftBackground(
      child: Column(
        children: [
          const SimpleTopBar(title: 'Jobs'),
          Expanded(
            child: ListView(
              controller: _scrollCtrl,
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
              children: [
                CardShell(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Work With Us',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: Brand.primaryBlue,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _jobDescriptions[_descIndex],
                        style: TextStyle(
                          color: Brand.mainText.withValues(alpha: 0.8),
                          fontWeight: FontWeight.w600,
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 14),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: () {
                            final next = !_showApplyForm;
                            setState(() => _showApplyForm = next);
                            if (next) {
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                if (!mounted || !_scrollCtrl.hasClients) return;
                                final target =
                                    _scrollCtrl.position.maxScrollExtent;
                                _scrollCtrl.animateTo(
                                  target,
                                  duration: const Duration(milliseconds: 320),
                                  curve: Curves.easeOutCubic,
                                );
                              });
                            }
                          },
                          icon: Icon(
                            _showApplyForm
                                ? Icons.expand_less_rounded
                                : Icons.send_rounded,
                          ),
                          label: Text(
                            _showApplyForm
                                ? 'Hide Application Form'
                                : 'Apply Now',
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (_showApplyForm) ...[
                  const SizedBox(height: 12),
                  CardShell(
                    child: JobApplicationScreen(
                      onSubmitted: () {
                        if (!mounted) return;
                        setState(() => _showApplyForm = false);
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _GuestJobApplyLimiter {
  static const Duration cooldown = Duration(hours: 24);
  static const String _key = 'guest_job_apply_last_ms';

  static Future<DateTime?> _last() async {
    final sp = await SharedPreferences.getInstance();
    final ms = sp.getInt(_key);
    if (ms == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }

  static Future<bool> canApplyNow() async {
    final last = await _last();
    if (last == null) return true;
    return DateTime.now().difference(last) >= cooldown;
  }

  static Future<Duration> remaining() async {
    final last = await _last();
    if (last == null) return Duration.zero;
    final diff = DateTime.now().difference(last);
    if (diff >= cooldown) return Duration.zero;
    return cooldown - diff;
  }

  static Future<void> markNow() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setInt(_key, DateTime.now().millisecondsSinceEpoch);
  }
}

class JobApplicationScreen extends StatefulWidget {
  const JobApplicationScreen({super.key, this.onSubmitted});

  final VoidCallback? onSubmitted;

  @override
  State<JobApplicationScreen> createState() => _JobApplicationScreenState();
}

class _JobApplicationScreenState extends State<JobApplicationScreen> {
  final _formKey = GlobalKey<FormState>();
  final _fullNameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _positionCtrl = TextEditingController();
  final _captchaCtrl = TextEditingController();

  PlatformFile? _cvPdf;
  bool _submitting = false;

  int _captchaA = 2;
  int _captchaB = 3;

  @override
  void initState() {
    super.initState();
    _refreshCaptcha();
  }

  @override
  void dispose() {
    _fullNameCtrl.dispose();
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    _positionCtrl.dispose();
    _captchaCtrl.dispose();
    super.dispose();
  }

  void _refreshCaptcha() {
    final now = DateTime.now().millisecondsSinceEpoch;
    _captchaA = (now % 8) + 1;
    _captchaB = ((now ~/ 7) % 8) + 1;
    _captchaCtrl.clear();
    if (mounted) setState(() {});
  }

  String _fmt(Duration d) {
    if (d <= Duration.zero) return '0m';
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    if (h <= 0) return '${m}m';
    return '${h}h ${m}m';
  }

  String _fieldLabel(String en, String ar, bool forGuest) {
    if (!forGuest) return en;
    return '$en | $ar';
  }

  Future<void> _pickPdf() async {
    if (_submitting) return;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
      allowMultiple: false,
      withData: true,
    );
    if (!mounted) return;
    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;
    final ext = file.extension?.toLowerCase().trim() ?? '';
    if (ext != 'pdf') {
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('Please select a PDF file only.')),
      );
      return;
    }

    setState(() => _cvPdf = file);
  }

  Future<String> _uploadCv(PlatformFile file) async {
    final request = http.MultipartRequest(
      'POST',
      BackendApi.uri('upload_job_cv.php'),
    );

    if (kIsWeb) {
      final bytes = file.bytes;
      if (bytes == null || bytes.isEmpty) {
        throw Exception('Could not read selected file bytes.');
      }
      request.files.add(
        http.MultipartFile.fromBytes('file', bytes, filename: file.name),
      );
    } else {
      final path = file.path;
      if (path == null || path.trim().isEmpty) {
        throw Exception('Could not read selected file path.');
      }
      request.files.add(await http.MultipartFile.fromPath('file', path));
    }

    final stream = await request.send();
    final response = await http.Response.fromStream(stream);
    final raw = response.body.trim();
    Map<String, dynamic>? data;

    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        data = decoded;
      }
    } catch (_) {
      final first = raw.indexOf('{');
      final last = raw.lastIndexOf('}');
      if (first >= 0 && last > first) {
        final candidate = raw.substring(first, last + 1);
        try {
          final decoded = jsonDecode(candidate);
          if (decoded is Map<String, dynamic>) {
            data = decoded;
          }
        } catch (_) {}
      }
    }

    if (data == null) {
      if (response.statusCode == 404) {
        throw Exception(
          'CV upload endpoint not found (upload_job_cv.php). Please deploy backend update.',
        );
      }
      throw Exception(
        'CV upload failed: server did not return valid JSON (HTTP ${response.statusCode}).',
      );
    }

    if (data['success'] != true) {
      final msg = (data['message'] ?? 'CV upload failed.').toString();
      throw Exception(msg);
    }

    final url = (data['url'] ?? '').toString().trim();
    if (url.isEmpty) {
      throw Exception('CV upload URL is missing.');
    }
    return url;
  }

  bool _isEmail(String value) {
    return RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(value);
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    if (_submitting) return;

    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (_cvPdf == null) {
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('Please upload your CV as a PDF.')),
      );
      return;
    }

    final expected = (_captchaA + _captchaB).toString();
    if (_captchaCtrl.text.trim() != expected) {
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('Captcha is incorrect. Try again.')),
      );
      _refreshCaptcha();
      return;
    }

    final currentUser = FirebaseAuth.instance.currentUser;
    final isGuest = currentUser == null;
    if (isGuest) {
      final canApply = await _GuestJobApplyLimiter.canApplyNow();
      if (!canApply) {
        final rem = await _GuestJobApplyLimiter.remaining();
        if (!mounted) return;
        AppToast.fromSnackBar(
          context,
          SnackBar(
            content: Text(
              'You can submit one application every 24 hours. Try again in ${_fmt(rem)}.',
            ),
          ),
        );
        return;
      }
    }

    setState(() => _submitting = true);

    try {
      final cvUrl = await _uploadCv(_cvPdf!);

      final ref = FirebaseDatabase.instance.ref('job_applications').push();
      await ref.set({
        'full_name': _fullNameCtrl.text.trim(),
        'phone': _phoneCtrl.text.trim(),
        'email': _emailCtrl.text.trim().toLowerCase(),
        'position': _positionCtrl.text.trim(),
        'cv_pdf_url': cvUrl,
        'status': 'new',
        'submittedByUid': currentUser?.uid ?? '',
        'isGuest': isGuest,
        'createdAt': ServerValue.timestamp,
      });

      if (isGuest) {
        await _GuestJobApplyLimiter.markNow();
      }

      if (!mounted) return;
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('Application submitted successfully ✅')),
      );
      widget.onSubmitted?.call();
    } catch (e) {
      if (!mounted) return;
      AppToast.fromSnackBar(context, SnackBar(content: Text(toHumanError(e))));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isGuestViewer = FirebaseAuth.instance.currentUser == null;
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Application Form',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: Brand.primaryBlue,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _fullNameCtrl,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: _fieldLabel(
                'Full name',
                'الاسم الكامل',
                isGuestViewer,
              ),
            ),
            validator: (v) =>
                (v ?? '').trim().isEmpty ? 'Please enter your full name' : null,
          ),
          const SizedBox(height: 10),
          TextFormField(
            controller: _phoneCtrl,
            keyboardType: TextInputType.phone,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: _fieldLabel(
                'Phone number',
                'رقم الهاتف',
                isGuestViewer,
              ),
            ),
            validator: (v) {
              final value = (v ?? '').replaceAll(RegExp(r'\s+'), '');
              if (value.isEmpty) return 'Please enter your phone number';
              if (value.length < 8) return 'Phone number is too short';
              return null;
            },
          ),
          const SizedBox(height: 10),
          TextFormField(
            controller: _emailCtrl,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: _fieldLabel(
                'Email',
                'البريد الإلكتروني',
                isGuestViewer,
              ),
            ),
            validator: (v) {
              final value = (v ?? '').trim().toLowerCase();
              if (value.isEmpty) return 'Please enter your email';
              if (!_isEmail(value)) return 'Enter a valid email';
              return null;
            },
          ),
          const SizedBox(height: 10),
          TextFormField(
            controller: _positionCtrl,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: _fieldLabel('Position', 'الوظيفة', isGuestViewer),
            ),
            validator: (v) =>
                (v ?? '').trim().isEmpty ? 'Please enter a position' : null,
          ),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: _submitting ? null : _pickPdf,
            icon: const Icon(Icons.picture_as_pdf_rounded),
            label: Text(
              _cvPdf == null
                  ? _fieldLabel(
                      'Upload CV (PDF)',
                      'رفع السيرة الذاتية (PDF)',
                      isGuestViewer,
                    )
                  : 'CV selected: ${_cvPdf!.name}',
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  controller: _captchaCtrl,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: _fieldLabel(
                      'Captcha: $_captchaA + $_captchaB = ?',
                      'التحقق: $_captchaA + $_captchaB = ؟',
                      isGuestViewer,
                    ),
                  ),
                  validator: (v) => (v ?? '').trim().isEmpty
                      ? 'Please solve the captcha'
                      : null,
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                onPressed: _submitting ? null : _refreshCaptcha,
                icon: const Icon(Icons.refresh_rounded),
                tooltip: 'New captcha',
              ),
            ],
          ),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _submitting ? null : _submit,
              icon: _submitting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send_rounded),
              label: Text(
                _submitting
                    ? 'Submitting...'
                    : _fieldLabel(
                        'Submit Application',
                        'إرسال الطلب',
                        isGuestViewer,
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class StoriesHome extends StatelessWidget {
  const StoriesHome({super.key});

  @override
  Widget build(BuildContext context) {
    return SoftBackground(child: const LearnerStoriesScreen());
  }
}

class GamesHome extends StatelessWidget {
  const GamesHome({super.key});

  @override
  Widget build(BuildContext context) {
    return SoftBackground(child: const LearnerGamesScreen());
  }
}

class GalleryHome extends StatelessWidget {
  const GalleryHome({super.key});

  @override
  Widget build(BuildContext context) {
    return const _PublicGalleryShowcase();
  }
}
