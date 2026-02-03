import 'dart:math';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../teacher/teacher_home.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();

  bool _isLogin = true;
  bool _busy = false;
  String? _error;

  // easy captcha (math)
  late int _a;
  late int _b;
  final _captchaCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _newCaptcha();
  }

  void _newCaptcha() {
    final r = Random();
    _a = r.nextInt(9) + 1;
    _b = r.nextInt(9) + 1;
    _captchaCtrl.clear();
  }

  bool _captchaOk() {
    final v = int.tryParse(_captchaCtrl.text.trim());
    return v == (_a + _b);
  }

  Future<void> _ensureUserRecord({required User user}) async {
    final ref = FirebaseDatabase.instance.ref('users/${user.uid}');
    final snap = await ref.get();

    if (!snap.exists) {
      await ref.set({
        'uid': user.uid,
        'email': user.email ?? '',
        'role': 'learner', // default role (you will change to admin/teacher manually)
        'createdAt': ServerValue.timestamp,
        'isActive': true,
      });
    }
  }

  bool _isTeacherRole(String role) {
    final r = role.trim().toLowerCase();
    return r == 'teacher';
  }

  Future<String> _getUserRole(String uid) async {
    final roleRef = FirebaseDatabase.instance.ref('users/$uid/role');
    final snap = await roleRef.get();
    final role = (snap.value ?? 'learner').toString();
    return role;
  }

  Future<void> _routeUserByRole(User user) async {
    final role = await _getUserRole(user.uid);

    if (!mounted) return;

    if (_isTeacherRole(role)) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const TeacherHomeScreen()),
      );
    } else {
      // For now: do nothing (you can route learners later)
      // Example later: Navigator.of(context).pushReplacement(...);
    }
  }

  Future<void> _emailPasswordSubmit() async {
    setState(() {
      _error = null;
      _busy = true;
    });

    try {
      if (!_captchaOk()) {
        throw Exception('Captcha incorrect. Solve: $_a + $_b');
      }

      final email = _emailCtrl.text.trim();
      final pass = _passCtrl.text;

      if (email.isEmpty || pass.isEmpty) {
        throw Exception('Email and password are required.');
      }

      UserCredential cred;
      if (_isLogin) {
        cred = await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: email,
          password: pass,
        );
      } else {
        cred = await FirebaseAuth.instance.createUserWithEmailAndPassword(
          email: email,
          password: pass,
        );
      }

      final user = cred.user;
      if (user == null) throw Exception('Login failed.');

      await _ensureUserRecord(user: user);
      await _routeUserByRole(user);
    } catch (e) {
      setState(() {
        _error = e.toString();
        _newCaptcha();
      });
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _googleSignIn() async {
    setState(() {
      _error = null;
      _busy = true;
    });

    try {
      final googleUser = await GoogleSignIn().signIn();
      if (googleUser == null) return; // cancelled

      final googleAuth = await googleUser.authentication;

      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      final cred = await FirebaseAuth.instance.signInWithCredential(credential);
      final user = cred.user;
      if (user == null) throw Exception('Google sign-in failed.');

      await _ensureUserRecord(user: user);
      await _routeUserByRole(user);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _busy = false);
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
      appBar: AppBar(
        title: Text(_isLogin ? 'Sign in' : 'Create account'),
      ),
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
                  Text(
                    _error!,
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                  const SizedBox(height: 10),
                ],
                FilledButton(
                  onPressed: _busy ? null : _emailPasswordSubmit,
                  child: Text(_busy
                      ? 'Please wait...'
                      : (_isLogin ? 'Sign in' : 'Sign up')),
                ),
                const SizedBox(height: 10),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                    _isLogin = !_isLogin;
                    _error = null;
                    _newCaptcha();
                  }),
                  child: Text(_isLogin
                      ? "Don't have an account? Sign up"
                      : "Already have an account? Sign in"),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
