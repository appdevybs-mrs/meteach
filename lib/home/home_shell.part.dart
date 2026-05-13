part of '../main.dart';

enum AppMode { home, media, jobs }

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  AppMode mode = AppMode.home;

  static const double _desktopShellMinWidth = 1100;

  Widget _pageForMode(AppMode value) {
    switch (value) {
      case AppMode.home:
        return const AssistantHome();
      case AppMode.media:
        return const MediaHome();
      case AppMode.jobs:
        return const JobsHome();
    }
  }

  Future<void> _openLogin(BuildContext context) async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const LoginScreen()));
  }

  bool _isDesktopShell(BuildContext context) {
    return kIsWeb && MediaQuery.sizeOf(context).width >= _desktopShellMinWidth;
  }

  String _labelForMode(AppMode value) {
    switch (value) {
      case AppMode.home:
        return 'Home';
      case AppMode.media:
        return 'Media';
      case AppMode.jobs:
        return 'Jobs';
    }
  }

  Widget _buildDesktopShell(BuildContext context) {
    final currentPage = _pageForMode(mode);
    return SafeArea(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 10, 18),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.95),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: Brand.uiBorder),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.06),
                    blurRadius: 22,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: NavigationRail(
                extended: true,
                minExtendedWidth: 208,
                backgroundColor: Colors.transparent,
                selectedIndex: mode.index,
                useIndicator: true,
                labelType: NavigationRailLabelType.none,
                onDestinationSelected: (i) =>
                    setState(() => mode = AppMode.values[i]),
                leading: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 18, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const YbsBusyLogo(size: 42),
                      const SizedBox(height: 12),
                      Text(
                        'Your Bridge School',
                        style: TextStyle(
                          color: Brand.primaryBlue,
                          fontWeight: FontWeight.w900,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Browse the public app with a desktop-ready shell.',
                        style: TextStyle(
                          color: Brand.mainText.withValues(alpha: 0.72),
                          fontWeight: FontWeight.w600,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
                trailing: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
                  child: FilledButton.icon(
                    onPressed: () => _openLogin(context),
                    style: FilledButton.styleFrom(
                      backgroundColor: Brand.actionOrange,
                      foregroundColor: Colors.white,
                      minimumSize: const Size.fromHeight(48),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    icon: const Icon(Icons.login_rounded),
                    label: const Text('Login'),
                  ),
                ),
                destinations: const [
                  NavigationRailDestination(
                    icon: Icon(Icons.home_rounded),
                    label: Text('Home'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.perm_media_rounded),
                    label: Text('Media'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.work_outline_rounded),
                    label: Text('Jobs'),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 18, 18, 18),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.56),
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(
                    color: Brand.uiBorder.withValues(alpha: 0.9),
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(27),
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _labelForMode(mode),
                                    style: TextStyle(
                                      color: Brand.primaryBlue,
                                      fontWeight: FontWeight.w900,
                                      fontSize: 24,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'Desktop navigation keeps the current design while using larger screens intentionally.',
                                    style: TextStyle(
                                      color: Brand.mainText.withValues(
                                        alpha: 0.72,
                                      ),
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            OutlinedButton.icon(
                              onPressed: () => _openLogin(context),
                              icon: const Icon(Icons.login_rounded),
                              label: const Text('Login'),
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: 1),
                      Expanded(child: currentPage),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Brand.appBg,
      resizeToAvoidBottomInset: true,
      body: SafeArea(child: _pageForMode(mode)),
      floatingActionButton: mode == AppMode.jobs
          ? null
          : _PulsingLoginFab(onPressed: () => _openLogin(context)),
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
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.95),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Brand.uiBorder),
                ),
                child: TabBar(
                  labelColor: Brand.primaryBlue,
                  unselectedLabelColor: Brand.mainText.withValues(alpha: 0.74),
                  tabs: [
                    Tab(
                      height: 38,
                      icon: Icon(Icons.auto_stories_rounded, size: 18),
                      text: 'Stories',
                    ),
                    Tab(
                      height: 38,
                      icon: Icon(Icons.sports_esports_rounded, size: 18),
                      text: 'Games',
                    ),
                    Tab(
                      height: 38,
                      icon: Icon(Icons.photo_library_rounded, size: 18),
                      text: 'Gallery',
                    ),
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
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                const CardShell(child: JobApplicationScreen()),
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

  String _sanitizeEventPart(String raw) {
    return raw
        .trim()
        .replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
  }

  Future<void> _notifyAdminsJobApplication({
    required String appId,
    required bool isGuest,
  }) async {
    final actorUid = (FirebaseAuth.instance.currentUser?.uid ?? '').trim();
    if (actorUid.isEmpty) {
      return;
    }

    final safeAppId = _sanitizeEventPart(appId);
    if (safeAppId.isEmpty) return;

    final title = isGuest ? 'New guest job application' : 'New job application';
    final body = isGuest
        ? 'A new guest candidate submitted a job application.'
        : 'A new platform user submitted a job application.';

    try {
      await PushDispatchService.dispatchAdminTopic(
        intent: PushIntent.jobApplication,
        title: title,
        message: body,
        context: const PushDispatchContext(
          screen: 'home/job_application_screen',
          action: 'notify_admins_job_application',
        ),
        eventParts: ['job_application', safeAppId],
        route: 'job_applications',
        data: {
          'priority': 'high',
          'appId': appId,
          'isGuest': isGuest ? '1' : '0',
        },
      );
    } catch (_) {}
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    if (_submitting) return;

    if (!(_formKey.currentState?.validate() ?? false)) return;

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

    if (_cvPdf == null) {
      final okWithoutCv = await _confirmSubmitWithoutCv();
      if (!okWithoutCv) return;
    }

    setState(() => _submitting = true);

    try {
      String? cvUrl;
      final cvFile = _cvPdf;
      if (cvFile != null) {
        cvUrl = await _uploadCv(cvFile);
      }

      final ref = FirebaseDatabase.instance.ref('job_applications').push();
      final payload = <String, dynamic>{
        'full_name': _fullNameCtrl.text.trim(),
        'phone': _phoneCtrl.text.trim(),
        'email': _emailCtrl.text.trim().toLowerCase(),
        'position': _positionCtrl.text.trim(),
        'status': 'new',
        'submittedByUid': currentUser?.uid ?? '',
        'isGuest': isGuest,
        'createdAt': ServerValue.timestamp,
      };
      if (cvUrl != null && cvUrl.trim().isNotEmpty) {
        payload['cv_pdf_url'] = cvUrl.trim();
      }
      await ref.set(payload);

      await _notifyAdminsJobApplication(appId: ref.key ?? '', isGuest: isGuest);

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

  Future<bool> _confirmSubmitWithoutCv() async {
    final answer = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Submit without CV? | إرسال بدون سيرة ذاتية؟'),
        content: const Text(
          'You are about to send your application without attaching a CV PDF. Continue?\n\n'
          'أنت على وشك إرسال طلبك بدون إرفاق ملف السيرة الذاتية PDF. هل تريد المتابعة؟',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel | إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Send anyway | إرسال على أي حال'),
          ),
        ],
      ),
    );
    return answer ?? false;
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
                      'CV PDF (opt)',
                      'CV PDF (اختياري)',
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
              style: FilledButton.styleFrom(
                backgroundColor: Brand.actionOrange,
                foregroundColor: Colors.white,
              ),
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
                    : _fieldLabel('Submit', 'إرسال', isGuestViewer),
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
