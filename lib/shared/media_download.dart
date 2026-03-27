import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'app_feedback.dart';

class MediaDownload {
  static Future<void> downloadUrl(
    BuildContext context, {
    required String url,
    required String suggestedName,
    bool askFolder = true,
  }) async {
    final cleanedUrl = url.trim();
    if (cleanedUrl.isEmpty) {
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('No file URL to download.')),
      );
      return;
    }

    try {
      String? folder;
      if (askFolder) {
        folder = await FilePicker.platform.getDirectoryPath(
          dialogTitle: 'Choose folder to save file',
        );
      }
      folder ??= await _defaultDownloadsDirectoryPath();

      if ((folder ?? '').trim().isEmpty) {
        if (!context.mounted) return;
        AppToast.fromSnackBar(
          context,
          const SnackBar(
            content: Text('Download cancelled: no folder selected.'),
          ),
        );
        return;
      }

      final dir = Directory(folder!);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      final res = await http.get(Uri.parse(cleanedUrl));
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw Exception('Download failed (${res.statusCode})');
      }

      final fileName = _safeName(
        suggestedName,
        fallbackExt: _extFromUrl(cleanedUrl),
      );
      final out = File('${dir.path}/$fileName');
      await out.writeAsBytes(res.bodyBytes, flush: true);

      if (!context.mounted) return;
      AppToast.fromSnackBar(
        context,
        SnackBar(content: Text('Downloaded to ${out.path}')),
      );
    } catch (e) {
      if (!context.mounted) return;
      AppToast.fromSnackBar(
        context,
        SnackBar(content: Text('Download failed: $e')),
      );
    }
  }

  static String _extFromUrl(String u) {
    try {
      final uri = Uri.parse(u);
      final seg = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
      final i = seg.lastIndexOf('.');
      if (i > 0 && i < seg.length - 1) return seg.substring(i + 1);
    } catch (_) {}
    return 'bin';
  }

  static String _safeName(String raw, {required String fallbackExt}) {
    var s = raw.trim();
    if (s.isEmpty) {
      final stamp = DateTime.now().millisecondsSinceEpoch;
      s = 'media_$stamp.$fallbackExt';
    }
    s = s.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    if (!s.contains('.')) s = '$s.$fallbackExt';
    return s;
  }

  static Future<String?> _defaultDownloadsDirectoryPath() async {
    try {
      if (Platform.isAndroid) {
        const p = '/storage/emulated/0/Download';
        final d = Directory(p);
        if (await d.exists()) return d.path;
      }
      if (Platform.isLinux || Platform.isMacOS) {
        final home = Platform.environment['HOME'] ?? '';
        if (home.isNotEmpty) {
          final d = Directory('$home/Downloads');
          if (await d.exists()) return d.path;
        }
      }
      if (Platform.isWindows) {
        final profile = Platform.environment['USERPROFILE'] ?? '';
        if (profile.isNotEmpty) {
          final d = Directory('$profile\\Downloads');
          if (await d.exists()) return d.path;
        }
      }
    } catch (_) {}

    try {
      final docs = await getApplicationDocumentsDirectory();
      return docs.path;
    } catch (_) {
      return null;
    }
  }
}
