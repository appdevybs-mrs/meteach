import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../services/mail_consistency_service.dart';
import '../shared/app_feedback.dart';
import 'admin_learners.dart';
import 'admin_staff.dart';

Future<void> openAdminFilteredPeopleList(
  BuildContext context, {
  required String peerUid,
  required String peerName,
  String seedRole = '',
}) async {
  final uid = peerUid.trim();
  final filter = peerName.trim().isNotEmpty ? peerName.trim() : uid;

  if (filter.isEmpty) {
    if (!context.mounted) return;
    AppToast.fromSnackBar(
      context,
      const SnackBar(content: Text('No person is selected for this mail.')),
    );
    return;
  }

  var role = MailConsistencyService.normalizeRole(seedRole);
  if (role == 'unknown') {
    role = await MailConsistencyService.resolveUserRole(
      FirebaseDatabase.instance,
      uid,
      seedRole: seedRole,
    );
  }

  if (!context.mounted) return;

  Widget? target;
  switch (role) {
    case 'learner':
      target = AdminLearnersScreen(initialSearch: filter);
      break;
    case 'teacher':
    case 'staff':
    case 'admin':
      target = AdminStaffScreen(initialSearch: filter);
      break;
  }

  if (target == null) {
    AppToast.fromSnackBar(
      context,
      const SnackBar(
        content: Text('Could not decide which admin list to open.'),
      ),
    );
    return;
  }

  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => target!));
}
