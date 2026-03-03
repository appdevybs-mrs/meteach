import 'dart:io';

Future<void> deleteFileIfExists(String path) async {
  final f = File(path);
  if (await f.exists()) {
    await f.delete().catchError((_) {});
  }
}