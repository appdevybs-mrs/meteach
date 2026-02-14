import 'package:flutter/material.dart';
import '../main.dart'; // adjust if your main.dart path is different

class AdminPublicPreview extends StatelessWidget {
  const AdminPublicPreview({super.key});

  @override
  Widget build(BuildContext context) {
    // ✅ This opens the same assistant UI without AuthGate / logout logic
    return const AssistantHome();
  }
}
