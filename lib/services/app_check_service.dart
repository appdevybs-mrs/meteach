import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;

class AppCheckService {
  AppCheckService._();
  static final AppCheckService I = AppCheckService._();

  Future<void> activate() async {
    await FirebaseAppCheck.instance.activate(
      androidProvider: kDebugMode
          ? AndroidProvider.debug
          : AndroidProvider.playIntegrity,
      iosProvider: kDebugMode
          ? iOSProvider.debug
          : iOSProvider.deviceCheck,
      webProvider: kIsWeb
          ? kDebugMode
              ? ReCaptchaV3Provider('debug')
              : ReCaptchaV3Provider('your-recaptcha-v3-site-key')
          : null,
    );
  }
}
