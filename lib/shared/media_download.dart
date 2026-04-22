import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

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
      final out = await _prepareOutputFile(
        cleanedUrl,
        suggestedName,
        askFolder: askFolder,
      );

      final res = await http.get(Uri.parse(cleanedUrl));
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw Exception('Download failed (${res.statusCode})');
      }

      await out.writeAsBytes(res.bodyBytes, flush: true);

      if (!context.mounted) return;
      await _showDownloadActions(context, out);
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

  static Future<File> _prepareOutputFile(
    String cleanedUrl,
    String suggestedName, {
    required bool askFolder,
  }) async {
    final fileName = _safeName(
      suggestedName,
      fallbackExt: _extFromUrl(cleanedUrl),
    );

    if (Platform.isAndroid) {
      final baseDir = await getApplicationDocumentsDirectory();
      final targetDir = Directory('${baseDir.path}/downloads');
      if (!await targetDir.exists()) {
        await targetDir.create(recursive: true);
      }
      return File('${targetDir.path}/$fileName');
    }

    String? folder;
    if (askFolder) {
      folder = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Choose folder to save file',
      );
    }
    folder ??= await _defaultDownloadsDirectoryPath();

    if ((folder ?? '').trim().isEmpty) {
      throw Exception('Download cancelled: no folder selected.');
    }

    final dir = Directory(folder!);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return File('${dir.path}/$fileName');
  }

  static Future<void> _openDownloadedFile(
    BuildContext context,
    File file,
  ) async {
    try {
      final ok = await launchUrl(
        file.uri,
        mode: LaunchMode.externalApplication,
      );
      if (ok || !context.mounted) return;
      AppToast.fromSnackBar(
        context,
        const SnackBar(
          content: Text('Could not open file. Try Share instead.'),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      AppToast.fromSnackBar(
        context,
        SnackBar(content: Text('Could not open file: $e')),
      );
    }
  }

  static Future<void> _showDownloadActions(
    BuildContext context,
    File file,
  ) async {
    final showOpen = !Platform.isAndroid;
    final locationText = Platform.isAndroid
        ? 'Saved to app storage.'
        : 'Saved to ${file.path}';

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  file.uri.pathSegments.isNotEmpty
                      ? file.uri.pathSegments.last
                      : 'Downloaded file',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 8),
                Text(locationText),
                const SizedBox(height: 16),
                if (Platform.isAndroid)
                  Text(
                    'Use Share to open this file in another app.',
                    style: TextStyle(color: Colors.grey.shade700),
                  ),
                if (Platform.isAndroid) const SizedBox(height: 12),
                Row(
                  children: [
                    if (showOpen)
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () {
                            Navigator.of(sheetContext).pop();
                            _openDownloadedFile(context, file);
                          },
                          icon: const Icon(Icons.open_in_new_rounded),
                          label: const Text('Open'),
                        ),
                      ),
                    if (showOpen) const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () {
                          Navigator.of(sheetContext).pop();
                          Share.shareXFiles([XFile(file.path)]);
                        },
                        icon: const Icon(Icons.share_rounded),
                        label: Text(showOpen ? 'Share' : 'Share / Open'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
