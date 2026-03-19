import 'package:flutter/material.dart';

class RecordedCourseStudyScreen extends StatelessWidget {
  const RecordedCourseStudyScreen({
    super.key,
    required this.courseKey,
    required this.courseData,
  });

  final String courseKey;
  final Map<String, dynamic> courseData;

  @override
  Widget build(BuildContext context) {
    final title =
    (courseData['title'] ?? courseData['course_title'] ?? 'Recorded Course')
        .toString();

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
      ),
      body: const Center(
        child: Text('Recorded course study screen'),
      ),
    );
  }
}