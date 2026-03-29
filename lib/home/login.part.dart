part of '../main.dart';

class LoginScreen extends StatelessWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: SoftBackground(
          child: Column(
            children: [
              SimpleTopBar(
                title: 'Login',
                right: IconButton(
                  tooltip: 'Back',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded),
                  color: Brand.primaryBlue,
                ),
              ),
              Expanded(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(18, 10, 18, 18),
                      child: SingleChildScrollView(
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        padding: EdgeInsets.only(
                          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
                        ),
                        child: CardShell(
                          child: ClassroomLoginSection(onLoggedInAdmin: () {}),
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
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 10, 18, 18),
                  child: SingleChildScrollView(
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    padding: EdgeInsets.only(
                      bottom: MediaQuery.of(context).viewInsets.bottom + 16,
                    ),
                    child: CardShell(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 220),
                        child: showLogin
                            ? ClassroomLoginSection(
                                key: const ValueKey('login'),
                                onLoggedInAdmin: () {},
                              )
                            : Column(
                                key: const ValueKey('classroomInfo'),
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 54,
                                    height: 54,
                                    decoration: BoxDecoration(
                                      color: Brand.accentCyan.withValues(
                                        alpha: 0.12,
                                      ),
                                      borderRadius: BorderRadius.circular(16),
                                      border: Border.all(color: Brand.uiBorder),
                                    ),
                                    child: const Icon(
                                      Icons.school_rounded,
                                      color: Brand.primaryBlue,
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    'Classroom (Next)',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleLarge
                                        ?.copyWith(fontWeight: FontWeight.w900),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    'Next step: student/teacher login.\nTeachers mark attendance and post assignments.',
                                    textAlign: TextAlign.center,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(
                                          color: Brand.mainText.withValues(
                                            alpha: 0.75,
                                          ),
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
                                        horizontal: 16,
                                        vertical: 12,
                                      ),
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

  const ClassroomLoginSection({super.key, required this.onLoggedInAdmin});

  @override
  State<ClassroomLoginSection> createState() => _ClassroomLoginSectionState();
}

class _ClassroomLoginSectionState extends State<ClassroomLoginSection> {
  static const String supportWhatsAppNumber = '';
  static const String supportEmail = '';

  final emailCtrl = TextEditingController();
  final passCtrl = TextEditingController();
  final captchaCtrl = TextEditingController();

  bool loading = false;
  bool showPass = false;
  final bool _showSocialAuthButtons = false;
  String error = '';

  bool showCaptcha = true;
  int a = 2, b = 3;

  int failedAttempts = 0;
  DateTime? cooldownUntil;
  Timer? _cooldownTicker;

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
    a = (now % 8) + 1;
    b = ((now ~/ 7) % 8) + 1;
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

      if (!mounted) return;

      setState(() {
        loading = false;
        failedAttempts = 0;
      });

      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('Welcome back!')),
      );

      Navigator.of(context).pop();
    } on FirebaseAuthException catch (e) {
      failedAttempts += 1;
      showCaptcha = true;
      _refreshCaptcha();

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

    if (_isCoolingDown) {
      setState(
        () =>
            error = 'Please wait $_cooldownSecondsLeft seconds and try again.',
      );
      return;
    }

    const requireCaptchaNow = true;

    if (!_validateInputs(enforceCaptcha: requireCaptchaNow)) return;

    final email = emailCtrl.text.trim().toLowerCase();
    final pass = passCtrl.text;

    await _signInWithFirebase(email, pass);
  }

  Future<bool> _ensurePortalAccess() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return false;
    final db = FirebaseDatabase.instance.ref();
    final usersSnap = await db.child('users/${user.uid}').get();
    if (usersSnap.exists) return true;
    final adminSnap = await db.child('admins/${user.uid}').get();
    if (adminSnap.exists) return true;
    await FirebaseAuth.instance.signOut();
    if (!mounted) return false;
    setState(() {
      error =
          'Your account is not activated yet. Please contact administration.';
    });
    return false;
  }

  Future<void> _loginWithGoogle() async {
    if (loading || _isCoolingDown) return;
    FocusScope.of(context).unfocus();
    setState(() {
      loading = true;
      error = '';
    });
    try {
      if (kIsWeb) {
        await FirebaseAuth.instance.signInWithPopup(GoogleAuthProvider());
      } else {
        final googleUser = await GoogleSignIn().signIn();
        if (googleUser == null) {
          if (mounted) setState(() => loading = false);
          return;
        }
        final googleAuth = await googleUser.authentication;
        final credential = GoogleAuthProvider.credential(
          accessToken: googleAuth.accessToken,
          idToken: googleAuth.idToken,
        );
        await FirebaseAuth.instance.signInWithCredential(credential);
      }

      final allowed = await _ensurePortalAccess();
      if (!allowed || !mounted) return;
      setState(() {
        loading = false;
        failedAttempts = 0;
      });
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('Welcome back!')),
      );
      Navigator.of(context).pop();
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      setState(() {
        loading = false;
        error = _friendlyAuthMsg(e);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        loading = false;
        error = 'Google sign-in failed. Please try again.';
      });
    }
  }

  Future<void> _loginWithFacebook() async {
    if (loading || _isCoolingDown) return;
    FocusScope.of(context).unfocus();
    setState(() {
      loading = true;
      error = '';
    });
    try {
      if (kIsWeb) {
        await FirebaseAuth.instance.signInWithPopup(FacebookAuthProvider());
      } else {
        final result = await FacebookAuth.instance.login(
          permissions: const ['email', 'public_profile'],
        );
        if (result.status == LoginStatus.cancelled) {
          if (mounted) setState(() => loading = false);
          return;
        }
        if (result.status != LoginStatus.success ||
            result.accessToken == null) {
          throw FirebaseAuthException(
            code: 'facebook-login-failed',
            message: result.message ?? 'Facebook sign-in failed.',
          );
        }
        final credential = FacebookAuthProvider.credential(
          result.accessToken!.tokenString,
        );
        await FirebaseAuth.instance.signInWithCredential(credential);
      }

      final allowed = await _ensurePortalAccess();
      if (!allowed || !mounted) return;
      setState(() {
        loading = false;
        failedAttempts = 0;
      });
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('Welcome back!')),
      );
      Navigator.of(context).pop();
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      setState(() {
        loading = false;
        error = e.message?.trim().isNotEmpty == true
            ? e.message!.trim()
            : 'Facebook sign-in failed. Please try again.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        loading = false;
        error = 'Facebook sign-in failed. Please try again.';
      });
    }
  }

  Future<void> _forgotPassword() async {
    if (loading) return;

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

      await FirebaseAuth.instance.sendPasswordResetEmail(email: normalized);

      if (!mounted) return;
      setState(() => loading = false);

      AppToast.fromSnackBar(
        context,
        const SnackBar(
          content: Text(
            'If an account exists for that email, a reset link has been sent.',
          ),
        ),
      );
    } on FirebaseAuthException catch (_) {
      if (!mounted) return;
      setState(() => loading = false);

      AppToast.fromSnackBar(
        context,
        const SnackBar(
          content: Text(
            'If an account exists for that email, a reset link has been sent.',
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => loading = false);

      AppToast.fromSnackBar(
        context,
        const SnackBar(
          content: Text(
            'If an account exists for that email, a reset link has been sent.',
          ),
        ),
      );
    }
  }

  Future<void> _openWhatsApp() async {
    if (supportWhatsAppNumber.trim().isEmpty) return;

    final n = supportWhatsAppNumber.trim();
    final uri = Uri.parse('https://wa.me/$n');
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('Could not open WhatsApp.')),
      );
    }
  }

  Future<void> _emailSupport() async {
    if (supportEmail.trim().isEmpty) return;
    final uri = Uri.parse(
      'mailto:${supportEmail.trim()}?subject=Support%20Request',
    );
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('Could not open email app.')),
      );
    }
  }

  Widget _supportRow() {
    final hasWhatsApp = supportWhatsAppNumber.trim().isNotEmpty;
    final hasEmail = supportEmail.trim().isNotEmpty;

    if (!hasWhatsApp && !hasEmail) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 6),
        Text(
          'Need help?',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontWeight: FontWeight.w800,
            color: Brand.mainText.withValues(alpha: 0.75),
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
                icon: const Icon(Icons.chat_bubble_rounded, size: 18),
                label: const Text('WhatsApp'),
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
                      color: Colors.black.withValues(alpha: 0.06),
                      blurRadius: 18,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                padding: const EdgeInsets.all(12),
                child: Image.asset(
                  'assets/images/ybs_logo.png',
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => const Icon(
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
              onPressed: loading
                  ? null
                  : () => setState(() => showPass = !showPass),
              icon: Icon(showPass ? Icons.visibility_off : Icons.visibility),
            ),
          ),
          onSubmitted: (_) => loading ? null : _manualLogin(),
        ),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: loading ? null : _forgotPassword,
            child: const Text('Forgot password?'),
          ),
        ),
        const SizedBox(height: 6),
        if (_isCoolingDown) ...[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Brand.actionOrange.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: Brand.actionOrange.withValues(alpha: 0.35),
              ),
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
            color: Brand.accentCyan.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Brand.uiBorder),
          ),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: Brand.primaryBlue.withValues(alpha: 0.08),
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
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 10,
                    ),
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
        const SizedBox(height: 12),
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
        if (_showSocialAuthButtons) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Divider(color: Brand.uiBorder.withValues(alpha: 0.9)),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text(
                  'or continue with',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: Brand.mainText.withValues(alpha: 0.70),
                    fontSize: 12,
                  ),
                ),
              ),
              Expanded(
                child: Divider(color: Brand.uiBorder.withValues(alpha: 0.9)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            alignment: WrapAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: loading ? null : _loginWithGoogle,
                icon: const Icon(Icons.g_mobiledata_rounded),
                label: const Text('Google'),
              ),
              OutlinedButton.icon(
                onPressed: loading ? null : _loginWithFacebook,
                icon: const Icon(Icons.facebook_rounded),
                label: const Text('Facebook'),
              ),
            ],
          ),
        ],
        _supportRow(),
        if (error.isNotEmpty) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: cs.error.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: cs.error.withValues(alpha: 0.35)),
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
