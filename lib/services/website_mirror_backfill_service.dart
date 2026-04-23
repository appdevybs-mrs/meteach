import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

class WebsiteMirrorBackfillService {
  static const String _migrationKey = 'media_mirror_v3';

  static Future<void> runOnceForAdminLogin() async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;

    final adminUid = currentUser.uid.trim();
    if (adminUid.isEmpty) return;

    final rootRef = FirebaseDatabase.instance.ref();

    try {
      final adminSnap = await rootRef.child('admins/$adminUid').get();
      if (adminSnap.value != true) return;

      final migrationRef = rootRef.child('website/migrations/$_migrationKey');
      final migrationSnap = await migrationRef.get();
      final migrationMap = _asMap(migrationSnap.value);
      if (migrationMap['completed'] == true) return;

      await migrationRef.update({
        'status': 'running',
        'startedAt': ServerValue.timestamp,
        'startedBy': adminUid,
      });

      final results = await Future.wait([
        rootRef.child('users').get(),
        rootRef.child('learner_gallery').get(),
      ]);

      final usersMap = _asMap(results[0].value);
      final learnerGalleryMap = _asMap(results[1].value);

      final updates = <String, dynamic>{};

      var learnerGalleryCount = 0;
      learnerGalleryMap.forEach((learnerUidRaw, galleryRaw) {
        final learnerUid = learnerUidRaw.trim();
        if (learnerUid.isEmpty) return;

        final itemsMap = _asMap(galleryRaw);
        itemsMap.forEach((itemIdRaw, itemRaw) {
          final itemId = itemIdRaw.trim();
          if (itemId.isEmpty) return;
          final itemMap = _asMap(itemRaw);
          if (itemMap.isEmpty) return;

          updates['website/learners/$learnerUid/gallery/$itemId'] = itemMap;
          learnerGalleryCount += 1;
        });
      });

      var profileCount = 0;
      usersMap.forEach((uidRaw, userRaw) {
        final uid = uidRaw.trim();
        if (uid.isEmpty) return;

        final userMap = _asMap(userRaw);
        if (userMap.isEmpty) return;

        final role = _normalizedRole(userMap['role']);
        final roleNode = switch (role) {
          'learner' => 'learners',
          'teacher' => 'teachers',
          _ => '',
        };
        if (roleNode.isEmpty) return;

        updates['website/$roleNode/$uid/profile'] = _profileSnapshot(
          userMap,
          role: role,
        );
        profileCount += 1;
      });

      if (updates.isNotEmpty) {
        await rootRef.update(updates);
      }

      await migrationRef.update({
        'status': 'completed',
        'completed': true,
        'completedAt': ServerValue.timestamp,
        'completedBy': adminUid,
        'counts': {
          'learnerGallery': learnerGalleryCount,
          'profiles': profileCount,
          'totalWrites': updates.length,
        },
      });
    } catch (e) {
      await rootRef.child('website/migrations/$_migrationKey').update({
        'status': 'failed',
        'completed': false,
        'failedAt': ServerValue.timestamp,
        'failedBy': adminUid,
        'error': e.toString(),
      });
    }
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

  static String _normalizedRole(dynamic rawRole) {
    final role = _asString(rawRole).toLowerCase();
    if (role == 'teacher' || role == 'teachers' || role == 'teacher(s)') {
      return 'teacher';
    }
    if (role == 'learner' || role == 'learners' || role == 'learner(s)') {
      return 'learner';
    }
    return role;
  }

  static Map<String, dynamic> _profileSnapshot(
    Map<String, dynamic> userMap, {
    required String role,
  }) {
    final out = <String, dynamic>{
      'first_name': _asString(userMap['first_name']),
      'last_name': _asString(userMap['last_name']),
      'gender': _asString(userMap['gender']),
      'about_me': _asString(userMap['about_me']),
      'profile_photo': _asString(userMap['profile_photo']),
    };

    if (role == 'teacher') {
      final photos = _stringList(userMap['profile_photos']);
      final socialLinks = _asMap(userMap['social_links']);
      out['profile_photos'] = photos;
      if (photos.isNotEmpty && out['profile_photo'].toString().isEmpty) {
        out['profile_photo'] = photos.first;
      }
      out['intro_video_url'] = _asString(userMap['intro_video_url']);
      out['social_links'] = {
        'facebook': _asString(socialLinks['facebook']),
        'linkedin': _asString(socialLinks['linkedin']),
        'tiktok': _asString(socialLinks['tiktok']),
        'extra_url': _asString(socialLinks['extra_url']),
        'extra_icon': _asString(socialLinks['extra_icon']),
      };
      out['social_links_visible_to_learners'] =
          userMap['social_links_visible_to_learners'] != false;
    }

    return out;
  }
}
