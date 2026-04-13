import 'dart:async';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import '../shared/app_feedback.dart';

class BlockedActionScreen extends StatefulWidget {
  final String uid;
  final bool deleteAuth;
  final bool selfDeleteDone;

  const BlockedActionScreen({
    super.key,
    required this.uid,
    required this.deleteAuth,
    required this.selfDeleteDone,
  });

  @override
  State<BlockedActionScreen> createState() => _BlockedActionScreenState();
}

class _BlockedActionScreenState extends State<BlockedActionScreen> {
  void log(String msg) {}

  static const int _startSeconds = 5;
  Timer? _timer;

  int _secondsLeft = _startSeconds;
  bool _started = false;
  bool _isFinalizing = false;

  @override
  void initState() {
    super.initState();

    // Let UI render first, then start countdown
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

    log('Starting countdown: $_startSeconds seconds');

    _timer = Timer.periodic(const Duration(seconds: 1), (t) async {
      if (!mounted) return;

      if (_secondsLeft <= 1) {
        t.cancel();
        setState(() => _secondsLeft = 0);
        await _finalize();
        return;
      }

      setState(() => _secondsLeft -= 1);
    });
  }

  Future<void> _signOut() async {
    try {
      await FirebaseAuth.instance.signOut();
    } catch (e) {
      log('Sign out failed: $e');
    }
  }

  Future<void> _finalize() async {
    if (_isFinalizing) return;
    setState(() => _isFinalizing = true);

    final user = FirebaseAuth.instance.currentUser;

    try {
      if (user == null) {
        log('No current user, nothing to finalize.');
        return;
      }

      if (widget.selfDeleteDone == true) {
        log('selfDeleteDone=true → sign out only');
        await _signOut();
        return;
      }

      if (widget.deleteAuth != true) {
        log('deleteAuth=false → sign out only');
        await _signOut();
        return;
      }

      // Attempt delete (may fail if requires recent login / reauth)
      await user.reload();
      final fresh = FirebaseAuth.instance.currentUser;

      log('Attempting user.delete()...');
      await fresh?.delete();
      log('✅ user.delete() success');

      await FirebaseDatabase.instance.ref('users_blocked/${widget.uid}').update(
        {'selfDeleteDone': true, 'selfDeleteDoneAt': ServerValue.timestamp},
      );
    } catch (e) {
      log('❌ finalize error: $e');
      if (mounted) {
        AppToast.fromSnackBar(
          context,
          SnackBar(
            content: Text(
              'Couldn’t finalize automatically.\nPlease sign out.\n$e',
            ),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } finally {
      await _signOut(); // always end signed out
      if (mounted) {
        // don’t keep progress running forever if signOut fails
        setState(() => _isFinalizing = false);
      }
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
                  // ✅ Your logo asset
                  Image.asset('assets/images/ybs_logo.png', height: 100),
                  const SizedBox(height: 18),

                  Text(
                    'Access blocked',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 10),

                  Text(
                    'Your account has been blocked by Your Bridge School.\n'
                    'If you believe this is a mistake, please contact the administration.',
                    style: theme.textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 18),

                  // Countdown card
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
                          color: Colors.black.withValues(alpha: 0.05),
                        ),
                      ],
                    ),
                    child: Column(
                      children: [
                        Text(
                          _isFinalizing
                              ? 'Finalizing…'
                              : 'You will be signed out in',
                          style: theme.textTheme.bodyLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 10),

                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 250),
                          transitionBuilder: (child, anim) =>
                              ScaleTransition(scale: anim, child: child),
                          child: Text(
                            _isFinalizing ? '…' : '$_secondsLeft',
                            key: ValueKey(
                              _isFinalizing ? 'dots' : _secondsLeft,
                            ),
                            style: theme.textTheme.displaySmall?.copyWith(
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),

                        const SizedBox(height: 10),

                        LinearProgressIndicator(
                          value: _isFinalizing
                              ? null
                              : (_startSeconds - _secondsLeft) / _startSeconds,
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 18),

                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _isFinalizing
                              ? null
                              : () async {
                                  _timer?.cancel();
                                  await _finalize();
                                },
                          child: const Text('Sign out now'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          onPressed: _isFinalizing
                              ? null
                              : () => Navigator.of(context).maybePop(),
                          child: const Text('Back'),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 12),

                  Text(
                    'Your Bridge School',
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
