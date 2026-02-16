import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

class DeletedActionScreen extends StatefulWidget {
  final String uid;
  final bool deleteAuth;
  final bool selfDeleteDone;

  const DeletedActionScreen({
    super.key,
    required this.uid,
    required this.deleteAuth,
    required this.selfDeleteDone,
  });

  @override
  State<DeletedActionScreen> createState() => _DeletedActionScreenState();
}

class _DeletedActionScreenState extends State<DeletedActionScreen> {
  bool _ran = false;

  void log(String msg) => debugPrint('FIKRA_DELETED | $msg');

  Future<void> _signOut() async {
    await FirebaseAuth.instance.signOut();
  }

  Future<void> _tryDeleteAuthUserAndMarkDone() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    // If already done, skip delete and sign out
    if (widget.selfDeleteDone == true) {
      log('selfDeleteDone already true → just sign out');
      await _signOut();
      return;
    }

    // If deleteAuth flag is false, do not delete auth, just sign out
    if (widget.deleteAuth != true) {
      log('deleteAuth=false → just sign out');
      await _signOut();
      return;
    }

    try {
      // reload first (helps sometimes)
      await user.reload();
      final fresh = FirebaseAuth.instance.currentUser;

      log('Attempting user.delete()...');
      await fresh?.delete();

      log('✅ user.delete() success');

      // Mark done in RTDB
      await FirebaseDatabase.instance.ref('users_deleted/${widget.uid}').update({
        'selfDeleteDone': true,
        'selfDeleteDoneAt': ServerValue.timestamp,
      });
    } catch (e) {
      // Most common failure: requires-recent-login
      log('❌ user.delete() failed: $e');
    } finally {
      await _signOut();
      log('Signed out');
    }
  }

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (_ran) return;
      _ran = true;
      await _tryDeleteAuthUserAndMarkDone();
    });
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Padding(
          padding: EdgeInsets.all(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.delete_forever_rounded, size: 72),
              SizedBox(height: 12),
              Text('Account Removed', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
              SizedBox(height: 8),
              Text(
                'Your account has been removed.\nIf you think this is a mistake, please contact the school.',
                textAlign: TextAlign.center,
              ),
              SizedBox(height: 14),
              Text('Finalizing…'),
            ],
          ),
        ),
      ),
    );
  }
}
