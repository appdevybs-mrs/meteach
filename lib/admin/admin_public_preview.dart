import 'package:flutter/material.dart';
import '../main.dart'; // adjust if your main.dart path is different
import '../shared/admin_web_layout.dart';
import '../shared/admin_tour_guide.dart';

class AdminPublicPreview extends StatelessWidget {
  const AdminPublicPreview({super.key});

  @override
  Widget build(BuildContext context) {
    AdminTourGuide.scheduleSimple(
      context,
      screenId: 'admin_public_preview',
      title: 'معاينة الموقع العام',
      line: 'تعرض هذه الشاشة شكل الصفحة العامة كما يراها الزائر.',
    );

    return Scaffold(
      body: adminWebBodyFrame(
        context: context,
        child: const SafeArea(child: AssistantHome()),
      ),
    );
  }
}
