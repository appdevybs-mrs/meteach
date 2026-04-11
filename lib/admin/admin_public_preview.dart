import 'package:flutter/material.dart';
import '../main.dart'; // adjust if your main.dart path is different
import '../shared/admin_web_layout.dart';

class AdminPublicPreview extends StatelessWidget {
  const AdminPublicPreview({super.key});

  @override
  Widget build(BuildContext context) {

    return Scaffold(
      body: adminWebBodyFrame(
        context: context,
        child: const SafeArea(child: AssistantHome()),
      ),
    );
  }
}
