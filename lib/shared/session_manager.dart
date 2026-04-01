import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

class SessionManager {
  static final _db = FirebaseDatabase.instance.ref();
  static const _storage = FlutterSecureStorage();
  static const _key = 'active_session_id';

  static StreamSubscription<DatabaseEvent>? _sub;

  /// Call after login is confirmed
  static Future<void> createNewSessionAndStartListening() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    // Create new session id
    final newSessionId = const Uuid().v4();

    // Save locally
    await _storage.write(key: _key, value: newSessionId);

    // Write to RTDB (this invalidates other devices)
    await _db.child('sessions/$uid').set({
      'sessionId': newSessionId,
      'updatedAt': ServerValue.timestamp,
    });

    await Future.delayed(const Duration(milliseconds: 300));

    // Listen for changes
    await _sub?.cancel();
    final sessionRef = _db.child('sessions/$uid/sessionId');

    _sub = sessionRef.onValue.listen((event) async {
      final remote = event.snapshot.value?.toString() ?? '';
      final local = (await _storage.read(key: _key)) ?? '';

      // ✅ If sessionId is missing remotely (null/empty), DON'T logout.
      //    Just restore it (this prevents instant logout loops).
      if (remote.isEmpty && local.isNotEmpty) {
        await _db.child('sessions/$uid').update({
          'sessionId': local,
          'updatedAt': ServerValue.timestamp,
        });
        return;
      }

      // ✅ If mismatch happens, DO NOT logout immediately.
      //    Re-check from server once (prevents “old value first” glitch).
      if (local.isNotEmpty && remote.isNotEmpty && remote != local) {
        try {
          await Future.delayed(const Duration(milliseconds: 500));
          final fresh = (await sessionRef.get()).value?.toString() ?? '';

          // Still mismatched? then it’s a real other-device login → logout.
          if (fresh.isNotEmpty && fresh != local) {
            await forceLogout();
          }
        } catch (_) {
          // If get() fails, don't logout blindly.
        }
      }
    });
  }

  static Future<void> stopListening() async {
    await _sub?.cancel();
    _sub = null;
  }

  static Future<void> forceLogout() async {
    await stopListening();
    await _storage.delete(key: _key);
    await FirebaseAuth.instance.signOut();
  }
}
