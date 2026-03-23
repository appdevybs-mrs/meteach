import 'dart:async';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import '../shared/app_feedback.dart';
import '../shared/session_manager.dart';

import '../learner/learner_home.dart';
import '../admin/admin_home.dart';
import '../teacher/teacher_home.dart';
import 'not_authorized.dart';
import '../services/topic_service.dart';
import '../services/fcm_service.dart';

import 'deleted_action_screen.dart';
import 'blocked_action_screen.dart';
import 'paused_action_screen.dart';

class AuthGate extends StatefulWidget {
  final Widget signedOutHome;
  const AuthGate({super.key, required this.signedOutHome});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  bool _sessionStarted = false;
  String? _sessionUid;

  void log(String msg) {}

  String normRole(String? role) {
    final s = (role ?? '').toLowerCase();
    return s
        .replaceAll(RegExp(r'[\s\u00A0\u200B\u200C\u200D\uFEFF]+'), '')
        .trim();
  }

  @override
  Widget build(BuildContext context) {
    log('AuthGate build() ✅ NEW ROUTER ✅');

    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, authSnap) {
        if (authSnap.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(
              child: BrandedInlineLoader(message: 'Checking account...'),
            ),
          );
        }

        final user = authSnap.data;
        if (user == null) {
          final previousUid = _sessionUid;
          _sessionStarted = false;
          _sessionUid = null;
          SessionManager.stopListening(); // stop session listener when signed out
          if (previousUid != null && previousUid.isNotEmpty) {
            unawaited(TopicService.clearForUser(previousUid));
          }
          return widget.signedOutHome;
        }

        final uid = user.uid;

        final usersRef = FirebaseDatabase.instance.ref('users/$uid');

        return StreamBuilder<DatabaseEvent>(
          stream: usersRef.onValue,
          builder: (context, userEvent) {
            if (userEvent.connectionState == ConnectionState.waiting) {
              return const Scaffold(
                body: Center(
                  child: BrandedInlineLoader(message: 'Loading profile...'),
                ),
              );
            }

            if (userEvent.hasError) {
              return Scaffold(
                body: Center(
                  child: Text('User stream error:\n${userEvent.error}'),
                ),
              );
            }

            final snap = userEvent.data?.snapshot;
            final existsInUsers = snap?.exists == true;

            // If /users/{uid} missing => check users_deleted/users_blocked
            if (!existsInUsers) {
              final delRef = FirebaseDatabase.instance.ref(
                'users_deleted/$uid',
              );
              final blkRef = FirebaseDatabase.instance.ref(
                'users_blocked/$uid',
              );

              return FutureBuilder<List<DataSnapshot>>(
                future: Future.wait([delRef.get(), blkRef.get()]),
                builder: (context, checks) {
                  if (!checks.hasData) {
                    return const Scaffold(
                      body: Center(
                        child: BrandedInlineLoader(
                          message: 'Checking status...',
                        ),
                      ),
                    );
                  }

                  final delSnap = checks.data![0];
                  final blkSnap = checks.data![1];

                  if (delSnap.exists) {
                    // Read flags
                    final raw = delSnap.value;
                    final m = raw is Map
                        ? raw.map((k, v) => MapEntry(k.toString(), v))
                        : <String, dynamic>{};

                    final deleteAuth = (m['deleteAuth'] == true);
                    final selfDeleteDone = (m['selfDeleteDone'] == true);

                    log(
                      '🚫 Found in users_deleted | deleteAuth=$deleteAuth selfDeleteDone=$selfDeleteDone',
                    );

                    return DeletedActionScreen(
                      uid: uid,
                      deleteAuth: deleteAuth,
                      selfDeleteDone: selfDeleteDone,
                    );
                  }

                  if (blkSnap.exists) {
                    // Optional flags for blocked too
                    final raw = blkSnap.value;
                    final m = raw is Map
                        ? raw.map((k, v) => MapEntry(k.toString(), v))
                        : <String, dynamic>{};

                    final deleteAuth = (m['deleteAuth'] == true);
                    final selfDeleteDone = (m['selfDeleteDone'] == true);

                    log(
                      '⛔ Found in users_blocked | deleteAuth=$deleteAuth selfDeleteDone=$selfDeleteDone',
                    );

                    return BlockedActionScreen(
                      uid: uid,
                      deleteAuth: deleteAuth,
                      selfDeleteDone: selfDeleteDone,
                    );
                  }

                  return DeletedActionScreen(
                    uid: uid,
                    deleteAuth: true,
                    selfDeleteDone: false,
                  );
                },
              );
            }

            // Exists in /users => parse role/status
            final raw = snap!.value;
            final m = raw is Map
                ? raw.map((k, v) => MapEntry(k.toString(), v))
                : <String, dynamic>{};

            final status = (m['status'] ?? '').toString().toLowerCase().trim();
            // ✅ NEW: Always check if user is in users_deleted FIRST
            final delRefEarly = FirebaseDatabase.instance.ref(
              'users_deleted/$uid',
            );

            return FutureBuilder<DataSnapshot>(
              future: delRefEarly.get(),
              builder: (context, delSnapEarly) {
                if (!delSnapEarly.hasData) {
                  return const Scaffold(
                    body: Center(
                      child: BrandedInlineLoader(
                        message: 'Verifying access...',
                      ),
                    ),
                  );
                }

                if (delSnapEarly.data!.exists) {
                  final rawDel = delSnapEarly.data!.value;
                  final mm = rawDel is Map
                      ? rawDel.map((k, v) => MapEntry(k.toString(), v))
                      : <String, dynamic>{};

                  final deleteAuth = (mm['deleteAuth'] == true);
                  final selfDeleteDone = (mm['selfDeleteDone'] == true);

                  return DeletedActionScreen(
                    uid: uid,
                    deleteAuth: deleteAuth,
                    selfDeleteDone: selfDeleteDone,
                  );
                }

                // ⬇️ If NOT deleted, continue normal logic below

                final role = normRole(m['role']?.toString());

                log('ROLE=[$role] STATUS=[$status]');

                // Paused => separate screen
                if (status == 'paused') {
                  return const PausedActionScreen();
                }

                // ✅ Blocked (when /users/$uid still exists)
                if (status == 'blocked') {
                  final blkRef = FirebaseDatabase.instance.ref(
                    'users_blocked/$uid',
                  );

                  return FutureBuilder<DataSnapshot>(
                    future: blkRef.get(),
                    builder: (context, snap2) {
                      if (!snap2.hasData) {
                        return const Scaffold(
                          body: Center(
                            child: BrandedInlineLoader(
                              message: 'Finalizing access...',
                            ),
                          ),
                        );
                      }

                      final blkSnap = snap2.data!;
                      final raw2 = blkSnap.value;
                      final mm = raw2 is Map
                          ? raw2.map((k, v) => MapEntry(k.toString(), v))
                          : <String, dynamic>{};

                      final deleteAuth = (mm['deleteAuth'] == true);
                      final selfDeleteDone = (mm['selfDeleteDone'] == true);

                      log(
                        '⛔ status=blocked | users_blocked exists=${blkSnap.exists} deleteAuth=$deleteAuth selfDeleteDone=$selfDeleteDone',
                      );

                      return BlockedActionScreen(
                        uid: uid,
                        deleteAuth: deleteAuth,
                        selfDeleteDone: selfDeleteDone,
                      );
                    },
                  );
                }

                // Normal routing

                // ✅ single-device session: start ONCE per uid
                if (!_sessionStarted || _sessionUid != uid) {
                  _sessionStarted = true;
                  _sessionUid = uid;

                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    SessionManager.createNewSessionAndStartListening();
                  });
                }

                unawaited(
                  TopicService.syncForCurrentUser(role: role, uid: uid),
                );
                unawaited(FCMService.syncTokenAfterLogin());

                if (role == 'admin') return const AdminHome();

                if (role == 'teacher' ||
                    role == 'teachers' ||
                    role == 'teacher(s)' ||
                    role == 'Teacher') {
                  return const TeacherHomeScreen();
                }

                if (role == 'learner' ||
                    role == 'learners' ||
                    role == 'learner(s)') {
                  return const LearnerHome();
                }

                return NotAuthorized(role: role);
              },
            );
          },
        );
      },
    );
  }
}
