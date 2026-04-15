import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../shared/window_access_dialogs.dart';

class AppWindowRole {
  static const learner = 'learner';
  static const teacher = 'teacher';
  static const admin = 'admin';

  static const all = <String>[learner, teacher, admin];
}

class AppWindowKeys {
  static const learnerCourses = 'courses';
  static const learnerBooking = 'booking';
  static const learnerMail = 'mail';
  static const learnerReminders = 'reminders';
  static const learnerHomework = 'homework';
  static const learnerGallery = 'gallery';
  static const learnerStories = 'stories';
  static const learnerGames = 'games';
  static const learnerStudyCoach = 'study_coach';
  static const learnerProfile = 'profile';
  static const learnerRegulations = 'regulations';
  static const learnerThemeSettings = 'theme_settings';

  static const teacherProfile = 'profile';
  static const teacherSchedule = 'schedule';
  static const teacherClasses = 'classes';
  static const teacherGallery = 'gallery';
  static const teacherGames = 'games';
  static const teacherStories = 'stories';
  static const teacherOnlineAvailability = 'online_availability';
  static const teacherOnlineCircle = 'online_circle';
  static const teacherMail = 'mail';
  static const teacherReminders = 'reminders';
  static const teacherWages = 'wages';
  static const teacherRegulations = 'regulations';
  static const teacherSyllabi = 'syllabi';
  static const teacherShared = 'shared';
  static const teacherMyPlatform = 'my_platform';
  static const teacherThemeSettings = 'theme_settings';
  static const teacherHomeworkInbox = 'homework_inbox';

  static const adminLearners = 'learners';
  static const adminClasses = 'classes';
  static const adminStaff = 'staff';
  static const adminPayments = 'payments';
  static const adminFinance = 'finance';
  static const adminSchedule = 'schedule';
  static const adminAttendance = 'attendance';
  static const adminCourses = 'courses';
  static const adminVocabLists = 'vocab_lists';
  static const adminCourseReviews = 'course_reviews';
  static const adminOnlineBooking = 'online_booking';
  static const adminReminders = 'reminders';
  static const adminPriorityAlerts = 'priority_alerts';
  static const adminNotificationAudit = 'notification_audit';
  static const adminWages = 'wages';
  static const adminTeacherAvailability = 'teacher_availability';
  static const adminSubscriptions = 'subscriptions';
  static const adminCertificates = 'certificates';
  static const adminFileManager = 'file_manager';
  static const adminSharedFiles = 'shared_files';
  static const adminPublicGallery = 'public_gallery';
  static const adminContract = 'contract';
  static const adminSettings = 'settings';
  static const adminJobApplications = 'job_applications';
}

class AppWindowDefinition {
  const AppWindowDefinition({
    required this.role,
    required this.key,
    required this.labelEn,
    required this.labelAr,
    required this.tab,
    required this.canClose,
    this.defaultEnabled = true,
  });

  final String role;
  final String key;
  final String labelEn;
  final String labelAr;
  final String tab;
  final bool canClose;
  final bool defaultEnabled;
}

class AppWindowState {
  const AppWindowState({required this.definition, required this.enabled});

  final AppWindowDefinition definition;
  final bool enabled;

  AppWindowState copyWith({bool? enabled}) {
    return AppWindowState(
      definition: definition,
      enabled: enabled ?? this.enabled,
    );
  }
}

class WindowAccessService {
  WindowAccessService._();

  static final WindowAccessService instance = WindowAccessService._();

  DatabaseReference get _root =>
      FirebaseDatabase.instance.ref('appConfig/window_access');

  static const List<AppWindowDefinition> definitions = [
    AppWindowDefinition(
      role: AppWindowRole.learner,
      key: AppWindowKeys.learnerCourses,
      labelEn: 'Courses',
      labelAr: 'الدورات',
      tab: 'Learning',
      canClose: false,
    ),
    AppWindowDefinition(
      role: AppWindowRole.learner,
      key: AppWindowKeys.learnerBooking,
      labelEn: 'Booking',
      labelAr: 'الحجز',
      tab: 'Learning',
      canClose: true,
    ),
    AppWindowDefinition(
      role: AppWindowRole.learner,
      key: AppWindowKeys.learnerMail,
      labelEn: 'Mail',
      labelAr: 'البريد',
      tab: 'Communication',
      canClose: true,
    ),
    AppWindowDefinition(
      role: AppWindowRole.learner,
      key: AppWindowKeys.learnerReminders,
      labelEn: 'Reminders',
      labelAr: 'التذكيرات',
      tab: 'Communication',
      canClose: true,
    ),
    AppWindowDefinition(
      role: AppWindowRole.learner,
      key: AppWindowKeys.learnerHomework,
      labelEn: 'Homework',
      labelAr: 'الواجب',
      tab: 'Learning',
      canClose: true,
    ),
    AppWindowDefinition(
      role: AppWindowRole.learner,
      key: AppWindowKeys.learnerGallery,
      labelEn: 'Gallery',
      labelAr: 'المعرض',
      tab: 'Media',
      canClose: true,
    ),
    AppWindowDefinition(
      role: AppWindowRole.learner,
      key: AppWindowKeys.learnerStories,
      labelEn: 'Stories',
      labelAr: 'القصص',
      tab: 'Media',
      canClose: true,
    ),
    AppWindowDefinition(
      role: AppWindowRole.learner,
      key: AppWindowKeys.learnerGames,
      labelEn: 'Games',
      labelAr: 'الألعاب',
      tab: 'Media',
      canClose: true,
    ),
    AppWindowDefinition(
      role: AppWindowRole.learner,
      key: AppWindowKeys.learnerStudyCoach,
      labelEn: 'Study Coach',
      labelAr: 'المدرب الدراسي',
      tab: 'Learning',
      canClose: true,
    ),
    AppWindowDefinition(
      role: AppWindowRole.learner,
      key: AppWindowKeys.learnerProfile,
      labelEn: 'Profile',
      labelAr: 'الملف الشخصي',
      tab: 'Account',
      canClose: false,
    ),
    AppWindowDefinition(
      role: AppWindowRole.learner,
      key: AppWindowKeys.learnerRegulations,
      labelEn: 'Regulations',
      labelAr: 'القوانين',
      tab: 'Account',
      canClose: true,
    ),
    AppWindowDefinition(
      role: AppWindowRole.learner,
      key: AppWindowKeys.learnerThemeSettings,
      labelEn: 'Theme Settings',
      labelAr: 'إعدادات المظهر',
      tab: 'Account',
      canClose: true,
    ),

    AppWindowDefinition(
      role: AppWindowRole.teacher,
      key: AppWindowKeys.teacherProfile,
      labelEn: 'Profile',
      labelAr: 'الملف الشخصي',
      tab: 'Core',
      canClose: false,
    ),
    AppWindowDefinition(
      role: AppWindowRole.teacher,
      key: AppWindowKeys.teacherSchedule,
      labelEn: 'Schedule',
      labelAr: 'الجدول',
      tab: 'Core',
      canClose: false,
    ),
    AppWindowDefinition(
      role: AppWindowRole.teacher,
      key: AppWindowKeys.teacherClasses,
      labelEn: 'My Classes',
      labelAr: 'حصصي',
      tab: 'Core',
      canClose: false,
    ),
    AppWindowDefinition(
      role: AppWindowRole.teacher,
      key: AppWindowKeys.teacherGallery,
      labelEn: 'Gallery',
      labelAr: 'المعرض',
      tab: 'Teaching',
      canClose: true,
    ),
    AppWindowDefinition(
      role: AppWindowRole.teacher,
      key: AppWindowKeys.teacherGames,
      labelEn: 'Games',
      labelAr: 'الألعاب',
      tab: 'Teaching',
      canClose: true,
    ),
    AppWindowDefinition(
      role: AppWindowRole.teacher,
      key: AppWindowKeys.teacherStories,
      labelEn: 'Stories',
      labelAr: 'القصص',
      tab: 'Teaching',
      canClose: true,
    ),
    AppWindowDefinition(
      role: AppWindowRole.teacher,
      key: AppWindowKeys.teacherOnlineAvailability,
      labelEn: 'Online Availability',
      labelAr: 'التوفر أونلاين',
      tab: 'Online',
      canClose: true,
    ),
    AppWindowDefinition(
      role: AppWindowRole.teacher,
      key: AppWindowKeys.teacherOnlineCircle,
      labelEn: 'Online Circle',
      labelAr: 'الدائرة أونلاين',
      tab: 'Online',
      canClose: true,
    ),
    AppWindowDefinition(
      role: AppWindowRole.teacher,
      key: AppWindowKeys.teacherMail,
      labelEn: 'Mail',
      labelAr: 'البريد',
      tab: 'Communication',
      canClose: true,
    ),
    AppWindowDefinition(
      role: AppWindowRole.teacher,
      key: AppWindowKeys.teacherReminders,
      labelEn: 'Reminders',
      labelAr: 'التذكيرات',
      tab: 'Communication',
      canClose: true,
    ),
    AppWindowDefinition(
      role: AppWindowRole.teacher,
      key: AppWindowKeys.teacherWages,
      labelEn: 'Wages',
      labelAr: 'الأجور',
      tab: 'Account',
      canClose: true,
    ),
    AppWindowDefinition(
      role: AppWindowRole.teacher,
      key: AppWindowKeys.teacherRegulations,
      labelEn: 'Regulations',
      labelAr: 'القوانين',
      tab: 'Account',
      canClose: true,
    ),
    AppWindowDefinition(
      role: AppWindowRole.teacher,
      key: AppWindowKeys.teacherSyllabi,
      labelEn: 'Syllabi',
      labelAr: 'المناهج',
      tab: 'Teaching',
      canClose: true,
    ),
    AppWindowDefinition(
      role: AppWindowRole.teacher,
      key: AppWindowKeys.teacherShared,
      labelEn: 'Shared',
      labelAr: 'المشترك',
      tab: 'Teaching',
      canClose: true,
    ),
    AppWindowDefinition(
      role: AppWindowRole.teacher,
      key: AppWindowKeys.teacherMyPlatform,
      labelEn: 'My Platform',
      labelAr: 'منصتي',
      tab: 'Teaching',
      canClose: true,
    ),
    AppWindowDefinition(
      role: AppWindowRole.teacher,
      key: AppWindowKeys.teacherThemeSettings,
      labelEn: 'Theme Settings',
      labelAr: 'إعدادات المظهر',
      tab: 'Account',
      canClose: true,
    ),
    AppWindowDefinition(
      role: AppWindowRole.teacher,
      key: AppWindowKeys.teacherHomeworkInbox,
      labelEn: 'Homework Inbox',
      labelAr: 'صندوق الواجب',
      tab: 'Communication',
      canClose: true,
    ),

    AppWindowDefinition(
      role: AppWindowRole.admin,
      key: AppWindowKeys.adminLearners,
      labelEn: 'Learners',
      labelAr: 'الطلاب',
      tab: 'Core',
      canClose: false,
    ),
    AppWindowDefinition(
      role: AppWindowRole.admin,
      key: AppWindowKeys.adminClasses,
      labelEn: 'Classes',
      labelAr: 'الحصص',
      tab: 'Core',
      canClose: false,
    ),
    AppWindowDefinition(
      role: AppWindowRole.admin,
      key: AppWindowKeys.adminStaff,
      labelEn: 'Staff',
      labelAr: 'الكادر',
      tab: 'Core',
      canClose: false,
    ),
    AppWindowDefinition(
      role: AppWindowRole.admin,
      key: AppWindowKeys.adminPayments,
      labelEn: 'Payments',
      labelAr: 'المدفوعات',
      tab: 'Operations',
      canClose: true,
    ),
    AppWindowDefinition(
      role: AppWindowRole.admin,
      key: AppWindowKeys.adminFinance,
      labelEn: 'Finance',
      labelAr: 'المالية',
      tab: 'Finance',
      canClose: true,
    ),
    AppWindowDefinition(
      role: AppWindowRole.admin,
      key: AppWindowKeys.adminSchedule,
      labelEn: 'Schedule',
      labelAr: 'الجدول',
      tab: 'Operations',
      canClose: true,
    ),
    AppWindowDefinition(
      role: AppWindowRole.admin,
      key: AppWindowKeys.adminAttendance,
      labelEn: 'Attendance',
      labelAr: 'الحضور',
      tab: 'Operations',
      canClose: true,
    ),
    AppWindowDefinition(
      role: AppWindowRole.admin,
      key: AppWindowKeys.adminCourses,
      labelEn: 'Courses',
      labelAr: 'الدورات',
      tab: 'Operations',
      canClose: true,
    ),
    AppWindowDefinition(
      role: AppWindowRole.admin,
      key: AppWindowKeys.adminVocabLists,
      labelEn: 'Vocabulary Lists',
      labelAr: 'قوائم المفردات',
      tab: 'Operations',
      canClose: true,
    ),
    AppWindowDefinition(
      role: AppWindowRole.admin,
      key: AppWindowKeys.adminCourseReviews,
      labelEn: 'Course Reviews',
      labelAr: 'مراجعات الدورات',
      tab: 'Operations',
      canClose: true,
    ),
    AppWindowDefinition(
      role: AppWindowRole.admin,
      key: AppWindowKeys.adminOnlineBooking,
      labelEn: 'Online Booking',
      labelAr: 'الحجز أونلاين',
      tab: 'Operations',
      canClose: true,
    ),
    AppWindowDefinition(
      role: AppWindowRole.admin,
      key: AppWindowKeys.adminReminders,
      labelEn: 'Reminders',
      labelAr: 'التذكيرات',
      tab: 'Communication',
      canClose: true,
    ),
    AppWindowDefinition(
      role: AppWindowRole.admin,
      key: AppWindowKeys.adminPriorityAlerts,
      labelEn: 'Priority Alerts',
      labelAr: 'تنبيهات مهمة',
      tab: 'Communication',
      canClose: true,
    ),
    AppWindowDefinition(
      role: AppWindowRole.admin,
      key: AppWindowKeys.adminNotificationAudit,
      labelEn: 'Notification Audit',
      labelAr: 'تدقيق الإشعارات',
      tab: 'Communication',
      canClose: true,
    ),
    AppWindowDefinition(
      role: AppWindowRole.admin,
      key: AppWindowKeys.adminWages,
      labelEn: 'Wages',
      labelAr: 'الأجور',
      tab: 'Finance',
      canClose: true,
    ),
    AppWindowDefinition(
      role: AppWindowRole.admin,
      key: AppWindowKeys.adminTeacherAvailability,
      labelEn: 'Teacher Availability',
      labelAr: 'توفّر المدرسين',
      tab: 'Operations',
      canClose: true,
    ),
    AppWindowDefinition(
      role: AppWindowRole.admin,
      key: AppWindowKeys.adminSubscriptions,
      labelEn: 'Subscriptions',
      labelAr: 'الاشتراكات',
      tab: 'Operations',
      canClose: true,
    ),
    AppWindowDefinition(
      role: AppWindowRole.admin,
      key: AppWindowKeys.adminCertificates,
      labelEn: 'Certificates',
      labelAr: 'الشهادات',
      tab: 'Operations',
      canClose: true,
    ),
    AppWindowDefinition(
      role: AppWindowRole.admin,
      key: AppWindowKeys.adminFileManager,
      labelEn: 'File Manager',
      labelAr: 'مدير الملفات',
      tab: 'Operations',
      canClose: true,
    ),
    AppWindowDefinition(
      role: AppWindowRole.admin,
      key: AppWindowKeys.adminSharedFiles,
      labelEn: 'Shared Files',
      labelAr: 'الملفات المشتركة',
      tab: 'Operations',
      canClose: true,
    ),
    AppWindowDefinition(
      role: AppWindowRole.admin,
      key: AppWindowKeys.adminPublicGallery,
      labelEn: 'Public Gallery',
      labelAr: 'المعرض العام',
      tab: 'Public',
      canClose: true,
    ),
    AppWindowDefinition(
      role: AppWindowRole.admin,
      key: AppWindowKeys.adminContract,
      labelEn: 'Contract',
      labelAr: 'العقود',
      tab: 'Operations',
      canClose: true,
    ),
    AppWindowDefinition(
      role: AppWindowRole.admin,
      key: AppWindowKeys.adminSettings,
      labelEn: 'Settings',
      labelAr: 'الإعدادات',
      tab: 'System',
      canClose: true,
    ),
    AppWindowDefinition(
      role: AppWindowRole.admin,
      key: AppWindowKeys.adminJobApplications,
      labelEn: 'Job Applications',
      labelAr: 'طلبات التوظيف',
      tab: 'Operations',
      canClose: true,
    ),
  ];

  AppWindowDefinition? definitionFor(String role, String key) {
    try {
      return definitions.firstWhere((d) => d.role == role && d.key == key);
    } catch (_) {
      return null;
    }
  }

  List<AppWindowDefinition> definitionsForRole(String role) {
    final out = definitions.where((d) => d.role == role).toList();
    out.sort((a, b) {
      final tabComp = a.tab.compareTo(b.tab);
      if (tabComp != 0) return tabComp;
      return a.labelEn.compareTo(b.labelEn);
    });
    return out;
  }

  bool _asBool(dynamic v, {required bool fallback}) {
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v == null) return fallback;
    final s = v.toString().trim().toLowerCase();
    if (s == 'true' || s == '1' || s == 'yes') return true;
    if (s == 'false' || s == '0' || s == 'no') return false;
    return fallback;
  }

  Map<String, dynamic> _defaultPayload({
    required AppWindowDefinition def,
    required String updatedBy,
  }) {
    return {
      'enabled': def.canClose ? def.defaultEnabled : true,
      'canClose': def.canClose,
      'labelEn': def.labelEn,
      'labelAr': def.labelAr,
      'tab': def.tab,
      'updatedBy': updatedBy,
      'updatedAt': ServerValue.timestamp,
    };
  }

  Future<void> seedDefaultsIfMissing({required String updatedBy}) async {
    try {
      final snap = await _root.get();
      final rootValue = snap.value;
      final rootMap = rootValue is Map
          ? Map<dynamic, dynamic>.from(rootValue)
          : <dynamic, dynamic>{};

      final updates = <String, dynamic>{};
      for (final def in definitions) {
        final roleNode = rootMap[def.role];
        final roleMap = roleNode is Map
            ? Map<dynamic, dynamic>.from(roleNode)
            : <dynamic, dynamic>{};
        final existingWindowNode = roleMap[def.key];

        if (existingWindowNode is! Map) {
          updates['${def.role}/${def.key}'] = _defaultPayload(
            def: def,
            updatedBy: updatedBy,
          );
        }
      }

      if (updates.isNotEmpty) {
        await _root.update(updates);
      }
    } catch (_) {}
  }

  Future<List<AppWindowState>> loadStatesForRole(String role) async {
    final defs = definitionsForRole(role);
    if (defs.isEmpty) return const [];

    Map<dynamic, dynamic> raw = const {};
    try {
      final snap = await _root.child(role).get();
      final value = snap.value;
      if (value is Map) {
        raw = Map<dynamic, dynamic>.from(value);
      }
    } catch (_) {}

    return defs.map((def) {
      final existing = raw[def.key];
      var enabled = def.defaultEnabled;
      if (existing is Map) {
        final m = existing.map((k, v) => MapEntry(k.toString(), v));
        enabled = _asBool(m['enabled'], fallback: def.defaultEnabled);
      }
      if (!def.canClose) {
        enabled = true;
      }
      return AppWindowState(definition: def, enabled: enabled);
    }).toList();
  }

  Future<bool> isWindowEnabled({
    required String role,
    required String windowKey,
  }) async {
    final def = definitionFor(role, windowKey);
    if (def == null) return true;
    if (!def.canClose) return true;

    try {
      final snap = await _root.child(role).child(windowKey).get();
      if (!snap.exists || snap.value is! Map) {
        return def.defaultEnabled;
      }
      final m = (snap.value as Map).map((k, v) => MapEntry(k.toString(), v));
      return _asBool(m['enabled'], fallback: def.defaultEnabled);
    } catch (_) {
      return true;
    }
  }

  Future<void> setWindowEnabled({
    required String role,
    required String windowKey,
    required bool enabled,
    required String updatedBy,
  }) async {
    final def = definitionFor(role, windowKey);
    if (def == null) return;
    if (!def.canClose && !enabled) return;

    await _root.child(role).child(windowKey).update({
      ..._defaultPayload(def: def, updatedBy: updatedBy),
      'enabled': def.canClose ? enabled : true,
    });
  }

  Future<void> guardOpen({
    required BuildContext context,
    required String role,
    required String windowKey,
    required VoidCallback onAllowed,
  }) async {
    final enabled = await isWindowEnabled(role: role, windowKey: windowKey);
    if (!context.mounted) return;

    if (!enabled) {
      await showWindowMaintenanceDialog(context);
      return;
    }
    onAllowed();
  }
}
