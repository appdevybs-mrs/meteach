import 'dart:io';
import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/material.dart';

Future<void> showBatteryOptimizationPopup(BuildContext context) async {
  if (!Platform.isAndroid) return;

  return showDialog(
    context: context,
    barrierDismissible: true,
    builder: (_) => AlertDialog(
      title: const Text("Enable Reliable Reminders"),
      content: const Text(
        "To make class reminders work even when the app is closed, please set Battery to 'No restrictions' for this app.\n\n"
        "On some phones (like Vivo), Battery saving can block alarms/notifications.",
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text("Later"),
        ),
        FilledButton(
          onPressed: () async {
            Navigator.pop(context);

            // Opens the battery optimization settings page (most Android devices)
            const intent = AndroidIntent(
              action: 'android.settings.IGNORE_BATTERY_OPTIMIZATION_SETTINGS',
            );
            await intent.launch();
          },
          child: const Text("Open Settings"),
        ),
      ],
    ),
  );
}
