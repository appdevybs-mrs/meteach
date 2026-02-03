import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

import '../admin/admin_home.dart';
import '../teacher/teacher_home.dart';
import 'not_authorized.dart';

class AuthGate extends StatelessWidget {
  final Widget signedOutHome;
  const AuthGate({super.key, required this.signedOutHome});

  void fikraLog(String msg) => print('FIKRA_AUTH | $msg');

  String normRole(String? role) {
    final s = (role ?? '').toLowerCase();
    // remove whitespace + NBSP + zero-width spaces
    return s.replaceAll(RegExp(r'[\s\u00A0\u200B\u200C\u200D\uFEFF]+'), '').trim();
  }

  Future<DataSnapshot> getSnap(String path) async {
    fikraLog('DB GET: $path');
    final ref = FirebaseDatabase.instance.ref(path);
    final snap = await ref.get();
    fikraLog('DB GOT: $path | exists=${snap.exists} | type=${snap.value.runtimeType} | value=${snap.value}');
    return snap;
  }

  @override
  Widget build(BuildContext context) {
    fikraLog('AuthGate build()');

    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, authSnap) {
        fikraLog('AUTH stream state=${authSnap.connectionState} hasData=${authSnap.hasData} hasError=${authSnap.hasError}');

        if (authSnap.connectionState == ConnectionState.waiting) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }

        if (authSnap.hasError) {
          fikraLog('AUTH ERROR: ${authSnap.error}');
          return Scaffold(body: Center(child: Text('Auth error:\n${authSnap.error}')));
        }

        final user = authSnap.data;
        if (user == null) {
          fikraLog('AUTH user=null -> signedOutHome');
          return signedOutHome;
        }

        fikraLog('AUTH user present uid=${user.uid} email=${user.email}');
        fikraLog('AUTH providers=${user.providerData.map((p) => p.providerId).toList()}');

        return FutureBuilder<DataSnapshot>(
          future: getSnap('users/${user.uid}'),
          builder: (context, userNodeSnap) {
            fikraLog('USER NODE future state=${userNodeSnap.connectionState} hasError=${userNodeSnap.hasError} hasData=${userNodeSnap.hasData}');

            if (userNodeSnap.connectionState == ConnectionState.waiting) {
              return const Scaffold(body: Center(child: CircularProgressIndicator()));
            }

            if (userNodeSnap.hasError) {
              fikraLog('USER NODE ERROR: ${userNodeSnap.error}');
              return Scaffold(body: Center(child: Text('User fetch error:\n${userNodeSnap.error}')));
            }

            final userNode = userNodeSnap.data!;
            if (!userNode.exists) {
              fikraLog('❌ Missing /users/${user.uid} -> NotAuthorized');
              return NotAuthorized(role: 'Missing /users/${user.uid}');
            }

            return FutureBuilder<DataSnapshot>(
              future: getSnap('users/${user.uid}/role'),
              builder: (context, roleSnap) {
                fikraLog('ROLE future state=${roleSnap.connectionState} hasError=${roleSnap.hasError} hasData=${roleSnap.hasData}');

                if (roleSnap.connectionState == ConnectionState.waiting) {
                  return const Scaffold(body: Center(child: CircularProgressIndicator()));
                }

                if (roleSnap.hasError) {
                  fikraLog('ROLE ERROR: ${roleSnap.error}');
                  return Scaffold(body: Center(child: Text('Role fetch error:\n${roleSnap.error}')));
                }

                final rawRole = roleSnap.data!.value?.toString();
                final role = normRole(rawRole);

                fikraLog('RAW ROLE=[$rawRole]');
                fikraLog('NORM ROLE=[$role]');

                if (role == 'admin') {
                  fikraLog('✅ ROUTE AdminHome');
                  return const AdminHome();
                }

                if (role == 'teacher' || role == 'teachers' || role == 'Teacher' || role == 'teacher(s)') {
                  fikraLog('✅ ROUTE TeacherHomeScreen');
                  return const TeacherHomeScreen();
                }

                if (role == 'learner' || role == 'learners' || role == 'learner(s)') {
                  fikraLog('✅ ROUTE signedOutHome (learner)');
                  return signedOutHome;
                }

                fikraLog('❌ UNKNOWN ROLE -> NotAuthorized rawRole=[$rawRole]');
                return NotAuthorized(role: rawRole);
              },
            );
          },
        );
      },
    );
  }
}
