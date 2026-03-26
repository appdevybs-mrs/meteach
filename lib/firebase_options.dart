// Generated manually from android/app/google-services.json.
// This is a minimal setup for Android.
import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions are not supported for this platform.',
        );
    }
  }

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyDH9PvQnz52kLziF7_M5i0ww6WeojNmRI8',
    appId: '1:723227930816:android:14df4f0edc2fc7b4c67d25',
    messagingSenderId: '723227930816',
    projectId: 'taqymn-dz',
    databaseURL: 'https://taqymn-dz-default-rtdb.firebaseio.com',
    storageBucket: 'taqymn-dz.firebasestorage.app',
  );
}
