import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_tour_guide.dart';

class FirstLoginAgreement {
  static const String _version = 'v1';

  static Future<void> ensureAccepted(
    BuildContext context, {
    required String roleKey,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final key = 'agreement_${_version}_${roleKey}_${user.uid}';
    final prefs = await SharedPreferences.getInstance();
    final localAccepted = prefs.getBool(key) ?? false;

    bool remoteAccepted = false;
    try {
      final snap = await FirebaseDatabase.instance
          .ref('users/${user.uid}/agreements/$roleKey')
          .get();
      if (snap.exists && snap.value is Map) {
        final m = (snap.value as Map).map((k, v) => MapEntry('$k', v));
        remoteAccepted =
            (m['acceptedVersion'] ?? '').toString().trim() == _version ||
            m['acceptedAt'] != null;
      }
    } catch (_) {}

    final accepted = localAccepted || remoteAccepted;
    if (accepted) {
      if (!localAccepted) {
        await prefs.setBool(key, true);
      }
      return;
    }
    if (!context.mounted) return;

    var agreeChecked = false;

    AppTourGuide.pause();
    try {
      while (context.mounted && !agreeChecked) {
        final result = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) {
            var checked = false;
            return StatefulBuilder(
              builder: (context, setState) {
                return Directionality(
                  textDirection: TextDirection.rtl,
                  child: AlertDialog(
                    title: const Text('اتفاقية الاستخدام والخدمات'),
                    content: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text(
                            'يرجى الاطلاع والموافقة على البنود التالية قبل المتابعة:',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            '1) شروط الاستخدام: الالتزام بالاستخدام المسؤول للمنصة.',
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            '2) اتفاقية الخدمات: تُقدَّم الخدمات التعليمية وفق سياسات الأكاديمية.',
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            '3) لوائح الأكاديمية: الالتزام بالأنظمة الأكاديمية والسلوكية المعتمدة.',
                          ),
                          const SizedBox(height: 12),
                          CheckboxListTile(
                            value: checked,
                            contentPadding: EdgeInsets.zero,
                            controlAffinity: ListTileControlAffinity.leading,
                            onChanged: (v) {
                              setState(() {
                                checked = v ?? false;
                              });
                            },
                            title: const Text(
                              'أوافق على الشروط والأحكام',
                              style: TextStyle(fontWeight: FontWeight.w800),
                            ),
                          ),
                        ],
                      ),
                    ),
                    actions: [
                      FilledButton(
                        onPressed: checked
                            ? () => Navigator.of(dialogContext).pop(true)
                            : null,
                        child: const Text('متابعة'),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        );

        if (result == true) {
          agreeChecked = true;
        }
      }
    } finally {
      AppTourGuide.resume();
    }

    if (agreeChecked) {
      await prefs.setBool(key, true);
      try {
        await FirebaseDatabase.instance
            .ref('users/${user.uid}/agreements/$roleKey')
            .update({
              'acceptedAt': ServerValue.timestamp,
              'acceptedVersion': _version,
            });
      } catch (_) {}
    }
  }
}
