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

    // Listen for changes
    await _sub?.cancel();
    _sub = _db.child('sessions/$uid/sessionId').onValue.listen((event) async {
      final remote = event.snapshot.value?.toString() ?? '';
      final local = (await _storage.read(key: _key)) ?? '';

      // if someone else logged in and overwrote sessionId -> logout
      if (local.isNotEmpty && remote.isNotEmpty && remote != local) {
        await forceLogout();
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
