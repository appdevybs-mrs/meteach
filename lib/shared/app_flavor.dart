class AppFlavor {
  static const String current = String.fromEnvironment(
    'APP_FLAVOR',
    defaultValue: 'prod',
  );
  static const bool isProd = current == 'prod';
  static const bool isTeacher = current == 'teacher';
}
