import 'package:flutter/material.dart';
import '../main.dart'; // adjust if your main.dart path is different

class AdminPublicPreview extends StatelessWidget {
  const AdminPublicPreview({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: SafeArea(child: AssistantHome()));
  }
}
