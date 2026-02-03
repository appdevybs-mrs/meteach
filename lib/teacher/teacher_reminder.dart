import 'package:flutter/material.dart';

class TeacherReminderScreen extends StatelessWidget {
  const TeacherReminderScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: SafeArea(
        child: Center(child: Text('Reminder (empty for now)')),
      ),
    );
  }
}
