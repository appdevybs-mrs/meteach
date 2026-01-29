import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

import '../admin/admin_home.dart';
import 'not_authorized.dart';

class AuthGate extends StatelessWidget {
  /// The app UI to show when user is NOT logged in.
  /// (Example: your HomeShell with tabs, where Classroom contains the login form)
  final Widget signedOutHome;

  const AuthGate({
    super.key,
    required this.signedOutHome,
  });

  Future<String?> _fetchRole(String uid) async {
    // Realtime Database path: users/{uid}/role
    final ref = FirebaseDatabase.instance.ref('users/$uid/role');
    final snap = await ref.get();
    if (!snap.exists) return null;
    return snap.value?.toString();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, authSnap) {
        if (authSnap.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        if (authSnap.hasError) {
          return Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline_rounded, size: 42),
                    const SizedBox(height: 10),
                    Text(
                      'Auth error:\n${authSnap.error}',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 14),
                    FilledButton(
                      onPressed: () async {
                        // Try to recover by signing out
                        await FirebaseAuth.instance.signOut();
                      },
                      child: const Text('Sign out'),
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        final user = authSnap.data;

        // ✅ NOT LOGGED IN -> show the main app (HomeShell) where Classroom has login
        if (user == null) {
          return signedOutHome;
        }

        // ✅ LOGGED IN -> check role
        return FutureBuilder<String?>(
          future: _fetchRole(user.uid),
          builder: (context, roleSnap) {
            if (roleSnap.connectionState == ConnectionState.waiting) {
              return const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              );
            }

            if (roleSnap.hasError) {
              return Scaffold(
                body: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.error_outline_rounded, size: 42),
                        const SizedBox(height: 10),
                        Text(
                          'Role fetch error:\n${roleSnap.error}',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 14),
                        FilledButton(
                          onPressed: () async {
                            await FirebaseAuth.instance.signOut();
                          },
                          child: const Text('Sign out'),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }

            final role = roleSnap.data;

            // ✅ ADMIN -> go to admin panel
            if (role == 'admin') {
              return const AdminHome();
            }

            // ✅ Logged in but not admin (or missing role)
            return NotAuthorized(role: role);
          },
        );
      },
    );
  }
}
