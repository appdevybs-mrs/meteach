import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:firebase_crashlytics/firebase_crashlytics.dart';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_gallery_saver/image_gallery_saver.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_feedback.dart';
import 'web_download.dart';

class MediaDownload {
  static bool _downloadInProgress = false;

  static Future<void> downloadUrl(
    BuildContext context, {
    required String url,
    required String suggestedName,
    bool askFolder = true,
    bool isVideo = false,
  }) async {
    if (_downloadInProgress) {
      if (!context.mounted) return;
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('A download is already in progress.')),
      );
      return;
    }

    final cleanedUrl = url.trim();
    if (cleanedUrl.isEmpty) {
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('No file URL to download.')),
      );
      return;
    }

    _downloadInProgress = true;
    try {
      final bytes = await _downloadWithProgress(
        context,
        url: cleanedUrl,
        label: 'Downloading file...',
      );

      final fileName = _safeName(
        suggestedName,
        fallbackExt: _extFromUrl(cleanedUrl),
      );

      if (kIsWeb) {
        downloadBytes(bytes, fileName);
        if (!context.mounted) return;
        AppToast.fromSnackBar(
          context,
          const SnackBar(content: Text('Download started.')),
        );
        return;
      }

      final tempDir = await getTemporaryDirectory();
      final tempFile = File('${tempDir.path}/$fileName');
      await tempFile.writeAsBytes(bytes, flush: true);

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
    } finally {
      _downloadInProgress = false;
    }
  }

  static Future<void> saveToGallery(
    BuildContext context, {
    required String url,
    required bool isVideo,
  }) async {
    if (kIsWeb) {
      throw UnsupportedError('Save to gallery is not supported on web.');
    }
    try {
      final bytes = await _downloadWithProgress(
        context,
        url: url,
        label: 'Saving to gallery...',
      );

      final fileName =
          'gallery_${DateTime.now().millisecondsSinceEpoch}.${_extFromUrl(url)}';
      final tempDir = await getTemporaryDirectory();
      final tempFile = File('${tempDir.path}/$fileName');
      await tempFile.writeAsBytes(bytes, flush: true);

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

  static Future<Uint8List> _downloadWithProgress(
    BuildContext context, {
    required String url,
    String? label,
  }) async {
    final progress = ValueNotifier<double>(0.0);
    final statusText = ValueNotifier<String>('Starting download...');

    final navigator = Navigator.of(context, rootNavigator: true);

    if (!context.mounted) throw Exception('Context no longer valid');

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: SizedBox(
            width: 300,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (label != null) ...[
                  Text(
                    label,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 16),
                ],
                ValueListenableBuilder<String>(
                  valueListenable: statusText,
                  builder: (_, s, _) => Text(
                    s,
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: 16),
                ValueListenableBuilder<double>(
                  valueListenable: progress,
                  builder: (_, p, _) => LinearProgressIndicator(
                    value: p > 0 ? p : null,
                  ),
                ),
                const SizedBox(height: 8),
                ValueListenableBuilder<double>(
                  valueListenable: progress,
                  builder: (_, p, _) => Text(
                    '${(p * 100).toStringAsFixed(0)}%',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(url.trim()));
      final streamedResponse = await client.send(request).timeout(const Duration(minutes: 5));

      if (streamedResponse.statusCode < 200 ||
          streamedResponse.statusCode >= 300) {
        throw Exception('Download failed (${streamedResponse.statusCode})');
      }

      final total = streamedResponse.contentLength;
      final bytes = <int>[];

      await for (final chunk in streamedResponse.stream) {
        bytes.addAll(chunk);
        if (total != null && total > 0) {
          progress.value = bytes.length / total;
          final downloaded = _formatBytes(bytes.length);
          final totalFormatted = _formatBytes(total);
          statusText.value = 'Downloading... $downloaded / $totalFormatted';
        } else {
          statusText.value = 'Downloading... ${_formatBytes(bytes.length)}';
        }
      }

      if (navigator.context.mounted) navigator.pop();
      return Uint8List.fromList(bytes);
    } catch (e) {
      if (navigator.context.mounted) navigator.pop();
      rethrow;
    } finally {
      client.close();
    }
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  static String _extFromUrl(String u) {
    try {
      final uri = Uri.parse(u);
      final seg = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
      final i = seg.lastIndexOf('.');
      if (i > 0 && i < seg.length - 1) return seg.substring(i + 1);
    } catch (e) {
      FirebaseCrashlytics.instance.recordError(e, StackTrace.current);
    }
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
    } catch (e) {
      FirebaseCrashlytics.instance.recordError(e, StackTrace.current);
    }

    try {
      final docs = await getApplicationDocumentsDirectory();
      return docs.path;
    } catch (e) {
      FirebaseCrashlytics.instance.recordError(e, StackTrace.current);
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
        } catch (e) {
          FirebaseCrashlytics.instance.recordError(e, StackTrace.current);
        }
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
                          context,
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
