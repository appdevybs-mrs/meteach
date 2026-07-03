import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

class PublicDataExportService {
  static Future<Map<String, int>> exportAll() async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) throw Exception('Not logged in.');

    final rootRef = FirebaseDatabase.instance.ref();

    final results = await Future.wait([
      rootRef.child('courses').get(),
      rootRef.child('website/teachers').get(),
    ]);

    final coursesMap = _asMap(results[0].value);
    final teachersMap = _asMap(results[1].value);

    final updates = <String, dynamic>{};

    var courseCount = 0;
    coursesMap.forEach((courseIdRaw, courseRaw) {
      final courseId = courseIdRaw.trim();
      if (courseId.isEmpty) return;

      final m = _asMap(courseRaw);
      if (m.isEmpty) return;

      final status = _asString(m['status']).toLowerCase();
      if (status == 'trashed' || status == 'deleted') return;

      updates['public_courses/$courseId'] = _coursePayload(courseId, m);
      courseCount += 1;
    });

    var teacherCount = 0;
    teachersMap.forEach((uidRaw, teacherData) {
      final uid = uidRaw.trim();
      if (uid.isEmpty) return;

      final profile = _asMap(teacherData['profile'] ?? teacherData);
      if (profile.isEmpty) return;

      updates['public_teachers/$uid'] = _teacherPayload(uid, profile);
      teacherCount += 1;
    });

    if (updates.isNotEmpty) {
      await rootRef.update(updates);
    }

    return {
      'courses': courseCount,
      'teachers': teacherCount,
      'writes': updates.length,
    };
  }

  static Map<String, dynamic> _coursePayload(
    String courseId,
    Map<String, dynamic> m,
  ) {
    final deliveryConfigs = _asMap(m['delivery_configs']);
    final fees = <String, dynamic>{};
    deliveryConfigs.forEach((key, value) {
      final config = _asMap(value);
      if (config['enabled'] == true) {
        fees[key] = config['fee'];
      }
    });

    final deliveryOptions = _stringList(m['delivery_options']);

    return {
      'courseId': courseId,
      'title': _asString(m['title']),
      'code': _asString(m['course_code']),
      'shortDescription': _asString(m['short_description']),
      'longDescription': _asString(m['long_description']),
      'category': _asString(m['category']),
      'level': _asString(m['level']),
      'language': _asString(m['language']),
      'duration': _asString(m['duration']),
      'cpdHours': _asString(m['cpd_hours']),
      'thumbnail': _asString(m['thumbnail']),
      'tags': _stringList(m['tags']),
      'deliveryModes': deliveryOptions,
      'fees': fees,
      'status': _asString(m['status']),
      'updatedAt': m['updatedAt'],
    };
  }

  static Map<String, dynamic> _teacherPayload(
    String uid,
    Map<String, dynamic> profile,
  ) {
    final first = _asString(profile['first_name']);
    final last = _asString(profile['last_name']);
    final fullName = '$first $last'.trim();

    final photos = _stringList(profile['profile_photos']);
    var photoUrl = _asString(profile['profile_photo']);
    if (photoUrl.isEmpty && photos.isNotEmpty) {
      photoUrl = photos.first;
    }

    final socialLinks = _asMap(profile['social_links']);

    return {
      'teacherId': uid,
      'fullName': fullName.isNotEmpty ? fullName : 'Teacher',
      'bio': _asString(profile['about_me']),
      'photoUrl': photoUrl,
      'profilePhotos': photos,
      'introVideoUrl': _asString(profile['intro_video_url']),
      'socialLinks': {
        'facebook': _asString(socialLinks['facebook']),
        'linkedin': _asString(socialLinks['linkedin']),
        'tiktok': _asString(socialLinks['tiktok']),
      },
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    };
  }

  static Map<String, dynamic> _asMap(dynamic value) {
    if (value is Map) {
      return value.map((key, data) => MapEntry(key.toString().trim(), data));
    }
    return <String, dynamic>{};
  }

  static String _asString(dynamic value) => (value ?? '').toString().trim();

  static List<String> _stringList(dynamic value) {
    if (value is List) {
      return value
          .map((item) => _asString(item))
          .where((item) => item.isNotEmpty)
          .toList();
    }
    if (value is Map) {
      final map = _asMap(value);
      final keys = map.keys.toList()..sort();
      return keys
          .map((key) => _asString(map[key]))
          .where((item) => item.isNotEmpty)
          .toList();
    }
    return const <String>[];
  }
}
