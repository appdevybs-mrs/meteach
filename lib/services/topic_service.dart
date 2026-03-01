import 'package:firebase_messaging/firebase_messaging.dart';

class TopicService {
  TopicService._();

  /// Call this after you know the user's role (admin/teacher/learner)
  static Future<void> subscribeForRole({required String role}) async {
    final r = role.toLowerCase().trim();

    // Subscribe based on role
    if (r == 'admin') {
      await FirebaseMessaging.instance.subscribeToTopic('admins');
    } else if (r == 'teacher' || r == 'teachers' || r == 'teacher(s)') {
      await FirebaseMessaging.instance.subscribeToTopic('teachers');
    } else if (r == 'learner' || r == 'learners' || r == 'learner(s)') {
      await FirebaseMessaging.instance.subscribeToTopic('learners');
    }

    // Optional: general topic for everyone
    await FirebaseMessaging.instance.subscribeToTopic('all');
  }

  /// Optional helper if you ever want to clean old topic when role changes
  static Future<void> unsubscribeAllRoleTopics() async {
    await FirebaseMessaging.instance.unsubscribeFromTopic('admins');
    await FirebaseMessaging.instance.unsubscribeFromTopic('teachers');
    await FirebaseMessaging.instance.unsubscribeFromTopic('learners');
    // keep 'all' if you want, or unsubscribe too:
    // await FirebaseMessaging.instance.unsubscribeFromTopic('all');
  }
}
