import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_gallery_saver/image_gallery_saver.dart';
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
    bool isVideo = false,
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
      final tempDir = await getTemporaryDirectory();
      final fileName = _safeName(
        suggestedName,
        fallbackExt: _extFromUrl(cleanedUrl),
      );
      final tempFile = File('${tempDir.path}/$fileName');

      final res = await http.get(Uri.parse(cleanedUrl));
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw Exception('Download failed (${res.statusCode})');
      }

      await tempFile.writeAsBytes(res.bodyBytes, flush: true);

      if (!context.mounted) return;
      await _showDownloadActions(
        context,
        file: tempFile,
        isVideo: isVideo,
        url: cleanedUrl,
        suggestedName: fileName,
      );
    } catch (e) {
      if (!context.mounted) return;
      AppToast.fromSnackBar(
        context,
        SnackBar(content: Text('Download failed: $e')),
      );
    }
  }

  static Future<void> saveToGallery({
    required String url,
    required bool isVideo,
  }) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final fileName =
          'gallery_${DateTime.now().millisecondsSinceEpoch}.${_extFromUrl(url)}';
      final tempFile = File('${tempDir.path}/$fileName');

      final res = await http.get(Uri.parse(url));
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw Exception('Download failed (${res.statusCode})');
      }

      await tempFile.writeAsBytes(res.bodyBytes, flush: true);

      final result = await ImageGallerySaver.saveFile(
        tempFile.path,
        isReturnPathOfIOS: false,
      );

      await tempFile.delete();

      if (result == null || result['isSuccess'] != true) {
        throw Exception('Save to gallery failed');
      }
    } catch (e) {
      rethrow;
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
      if (Platform.isLinux || Platform.isMacOS || Platform.isIOS) {
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
      final publicDir = Directory('/storage/emulated/0/Download');
      if (await publicDir.exists()) {
        try {
          final testFile = File(
            '${publicDir.path}/.ybs_test_${DateTime.now().millisecondsSinceEpoch}',
          );
          await testFile.writeAsBytes([0]);
          await testFile.delete();
          return File('${publicDir.path}/$fileName');
        } catch (_) {}
      }
      final appDir = await getApplicationDocumentsDirectory();
      final downloadsDir = Directory('${appDir.path}/downloads');
      if (!await downloadsDir.exists()) {
        await downloadsDir.create(recursive: true);
      }
      return File('${downloadsDir.path}/$fileName');
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
    BuildContext context, {
    required File file,
    required bool isVideo,
    required String url,
    required String suggestedName,
  }) async {
    final showOpen = !Platform.isAndroid;
    final isPublicDownloads =
        file.path.startsWith('/storage/emulated/0/Download');
    final locationText = isPublicDownloads
        ? 'Saved to Downloads folder.'
        : (Platform.isAndroid
            ? 'Saved to app storage.'
            : 'Saved to ${file.path}');

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
                const SizedBox(height: 8),
                Text(
                  'What would you like to do?',
                  style: TextStyle(
                    color: Colors.grey.shade700,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 16),
                // Save to Gallery
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () async {
                      Navigator.of(sheetContext).pop();
                      try {
                        await saveToGallery(
                          url: url,
                          isVideo: isVideo,
                        );
                        if (context.mounted) {
                          AppToast.fromSnackBar(
                            context,
                            const SnackBar(
                              content: Text('Saved to device gallery.'),
                            ),
                          );
                        }
                      } catch (e) {
                        if (context.mounted) {
                          AppToast.fromSnackBar(
                            context,
                            SnackBar(
                              content: Text('Could not save to gallery: $e'),
                            ),
                          );
                        }
                      }
                    },
                    icon: const Icon(Icons.photo_library_rounded),
                    label: const Text('Save to Gallery'),
                  ),
                ),
                const SizedBox(height: 8),
                // Save to Downloads (only on Android if not already there)
                if (Platform.isAndroid && !isPublicDownloads)
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        Navigator.of(sheetContext).pop();
                        try {
                          final publicDir =
                              Directory('/storage/emulated/0/Download');
                          if (await publicDir.exists()) {
                            final targetFile = File(
                              '${publicDir.path}/${file.uri.pathSegments.last}',
                            );
                            await file.copy(targetFile.path);
                            if (context.mounted) {
                              AppToast.fromSnackBar(
                                context,
                                const SnackBar(
                                  content:
                                      Text('Saved to Downloads folder.'),
                                ),
                              );
                            }
                          }
                        } catch (e) {
                          if (context.mounted) {
                            AppToast.fromSnackBar(
                              context,
                              SnackBar(
                                content: Text('Could not save: $e'),
                              ),
                            );
                          }
                        }
                      },
                      icon: const Icon(Icons.download_rounded),
                      label: const Text('Save to Downloads'),
                    ),
                  ),
                if (Platform.isAndroid && !isPublicDownloads)
                  const SizedBox(height: 8),
                // Share
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Navigator.of(sheetContext).pop();
                      Share.shareXFiles([XFile(file.path)]);
                    },
                    icon: const Icon(Icons.share_rounded),
                    label: const Text('Share'),
                  ),
                ),
                if (showOpen) ...[
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Navigator.of(sheetContext).pop();
                        _openDownloadedFile(context, file);
                      },
                      icon: const Icon(Icons.open_in_new_rounded),
                      label: const Text('Open'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
