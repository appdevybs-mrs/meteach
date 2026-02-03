import 'package:flutter/material.dart';

class TeacherMailScreen extends StatelessWidget {
  const TeacherMailScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: SafeArea(
        child: Center(child: Text('Mail (empty for now)')),
      ),
    );
  }
}
