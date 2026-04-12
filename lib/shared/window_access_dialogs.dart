import 'package:flutter/material.dart';

Future<void> showWindowMaintenanceDialog(BuildContext context) async {
  await showDialog<void>(
    context: context,
    builder: (_) => AlertDialog(
      title: const Text('Under Maintenance • قيد الصيانة'),
      content: const Text(
        'This part is under maintenance.\nهذا القسم قيد الصيانة حالياً.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

Future<bool> showWindowToggleConfirmDialog(
  BuildContext context, {
  required bool nextEnabled,
  required String labelEn,
  required String labelAr,
}) async {
  final actionEn = nextEnabled ? 'open' : 'close';
  final actionAr = nextEnabled ? 'فتح' : 'إغلاق';

  final result = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      title: const Text('Confirm action • تأكيد العملية'),
      content: Text(
        'Are you sure you want to $actionEn "$labelEn"?\n'
        'هل أنت متأكد أنك تريد $actionAr "$labelAr"؟',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(nextEnabled ? 'Open • فتح' : 'Close • إغلاق'),
        ),
      ],
    ),
  );

  return result == true;
}
