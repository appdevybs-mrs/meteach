import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

class PausedActionScreen extends StatefulWidget {
  const PausedActionScreen({super.key});

  @override
  State<PausedActionScreen> createState() => _PausedActionScreenState();
}

class _PausedActionScreenState extends State<PausedActionScreen> {
  static const int _startSeconds = 5;

  Timer? _timer;
  int _secondsLeft = _startSeconds;

  bool _isSigningOut = false;
  bool _started = false;

  void log(String msg) => debugPrint('FIKRA_PAUSED | $msg');

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _startCountdown();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _startCountdown() {
    if (_started) return;
    _started = true;

    _timer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (!mounted) return;

      if (_secondsLeft <= 1) {
        timer.cancel();
        setState(() => _secondsLeft = 0);
        await _signOut();
        return;
      }

      setState(() => _secondsLeft -= 1);
    });
  }

  Future<void> _signOut() async {
    if (_isSigningOut) return;
    _isSigningOut = true;

    try {
      log('Signing out paused user...');
      await FirebaseAuth.instance.signOut();
      log('Signed out');
    } catch (e) {
      log('Sign out failed: $e');
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error signing out: $e')),
      );

      setState(() {
        _isSigningOut = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [

                  /// 🔵 LOGO
                  Image.asset(
                    'assets/images/ybs_logo.png',
                    height: 100,
                  ),

                  const SizedBox(height: 20),

                  Text(
                    'Account Temporarily Paused',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
                    textAlign: TextAlign.center,
                  ),

                  const SizedBox(height: 12),

                  Text(
                    'Your account has been temporarily paused by the academy.\n'
                        'If you believe this is a mistake, please contact the administration.',
                    style: theme.textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),

                  const SizedBox(height: 20),

                  /// 🔵 COUNTDOWN CARD
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      color: theme.colorScheme.surface,
                      border: Border.all(color: theme.dividerColor),
                      boxShadow: [
                        BoxShadow(
                          blurRadius: 15,
                          offset: const Offset(0, 8),
                          color: Colors.black.withOpacity(0.05),
                        ),
                      ],
                    ),
                    child: Column(
                      children: [
                        Text(
                          _isSigningOut
                              ? 'Signing you out...'
                              : 'You will be signed out in',
                          style: theme.textTheme.bodyLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 10),

                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 250),
                          child: Text(
                            _isSigningOut ? '...' : '$_secondsLeft',
                            key: ValueKey(_secondsLeft),
                            style: theme.textTheme.displaySmall?.copyWith(
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),

                        const SizedBox(height: 10),

                        LinearProgressIndicator(
                          value: _isSigningOut
                              ? null
                              : (_startSeconds - _secondsLeft) / _startSeconds,
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 20),

                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _isSigningOut ? null : _signOut,
                          child: const Text('Sign out now'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          onPressed: _isSigningOut
                              ? null
                              : () => Navigator.of(context).maybePop(),
                          child: const Text('Back'),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 12),

                  Text(
                    'Dream English Academy',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.grey,
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
