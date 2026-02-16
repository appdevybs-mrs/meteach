import 'dart:math';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  void fikraLog(String msg) => print('FIKRA_AUTH | $msg');

  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();

  bool _busy = false;
  String? _error;

  late int _a;
  late int _b;
  final _captchaCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _newCaptcha();
    fikraLog('LoginScreen initState');
  }

  void _newCaptcha() {
    final r = Random();
    _a = r.nextInt(9) + 1;
    _b = r.nextInt(9) + 1;
    _captchaCtrl.clear();
    fikraLog('New captcha: $_a + $_b');
  }

  bool _captchaOk() {
    final v = int.tryParse(_captchaCtrl.text.trim());
    final ok = v == (_a + _b);
    fikraLog('Captcha input=$v ok=$ok');
    return ok;
  }

  Future<void> _emailPasswordLogin() async {
    setState(() {
      _error = null;
      _busy = true;
    });

    try {
      fikraLog('Email/Pass login pressed');

      if (!_captchaOk()) {
        throw Exception('Captcha incorrect. Solve: $_a + $_b');
      }

      final email = _emailCtrl.text.trim();
      final pass = _passCtrl.text;

      fikraLog('Trying sign-in email=$email passLen=${pass.length}');

      final cred = await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: email,
        password: pass,
      );

      final user = cred.user;
      fikraLog('Login success userNull=${user == null}');
      if (user != null) {
        fikraLog('AUTH uid=${user.uid} email=${user.email}');
        fikraLog('AUTH providers=${user.providerData.map((p) => p.providerId).toList()}');
      }

      if (!mounted) return;
      Navigator.of(context).pop(); // AuthGate routes
    } catch (e) {
      fikraLog('Login error: $e');
      setState(() {
        _error = e.toString();
        _newCaptcha();
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _googleSignIn() async {
    setState(() {
      _error = null;
      _busy = true;
    });

    try {
      fikraLog('Google sign-in start');

      // 1. Trigger the sign-in flow
      final GoogleSignInAccount? googleUser = await GoogleSignIn().signIn();

      if (googleUser == null) {
        fikraLog('Google sign-in cancelled by user');
        setState(() => _busy = false); // Reset busy if user just backed out
        return;
      }

      // 2. Obtain auth details from the request
      final GoogleSignInAuthentication googleAuth = await googleUser.authentication;

      // 3. Create a new credential
      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      // 4. Once signed in, Firebase will automatically link if "One account per email" is off,
      // or return the user if they already used Google before.
      final cred = await FirebaseAuth.instance.signInWithCredential(credential);

      fikraLog('Firebase sign-in successful: ${cred.user?.uid}');

      if (!mounted) return;

      // If you are using an AuthGate/StreamBuilder at the top of your app,
      // pop() is correct. If not, use pushReplacement.
      Navigator.of(context).pop();

    } on FirebaseAuthException catch (e) {
      fikraLog('Firebase Auth Error: ${e.code}');
      setState(() => _error = e.message);
    } catch (e) {
      fikraLog('General Error: $e');
      setState(() => _error = 'An unexpected error occurred.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passCtrl.dispose();
    _captchaCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sign in')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FilledButton.icon(
                  onPressed: _busy ? null : _googleSignIn,
                  icon: const Icon(Icons.g_mobiledata),
                  label: const Text('Continue with Google'),
                ),
                const SizedBox(height: 14),
                const Divider(),
                const SizedBox(height: 14),
                TextField(
                  controller: _emailCtrl,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _passCtrl,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Password',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _captchaCtrl,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: 'Captcha: $_a + $_b = ?',
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    IconButton(
                      tooltip: 'New captcha',
                      onPressed: _busy ? null : () => setState(_newCaptcha),
                      icon: const Icon(Icons.refresh),
                    )
                  ],
                ),
                const SizedBox(height: 14),
                if (_error != null) ...[
                  Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  const SizedBox(height: 10),
                ],
                FilledButton(
                  onPressed: _busy ? null : _emailPasswordLogin,
                  child: Text(_busy ? 'Please wait...' : 'Sign in'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
