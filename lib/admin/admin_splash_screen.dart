import 'dart:async';
import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:video_player/video_player.dart';

import '../services/backend_api.dart';
import '../services/splash_config_service.dart';
import '../shared/admin_web_layout.dart';

class AdminSplashScreen extends StatefulWidget {
  const AdminSplashScreen({super.key});

  @override
  State<AdminSplashScreen> createState() => _AdminSplashScreenState();
}

class _AdminSplashScreenState extends State<AdminSplashScreen> {
  static const _primaryBlue = Color(0xFF1A2B48);
  static const _actionOrange = Color(0xFFF98D28);
  static const _appBg = Color(0xFFF4F7F9);
  static const _uiBorder = Color(0xFFD1D9E0);
  static const _softText = Color(0xFF5E6B70);

  bool _loading = true;
  SplashConfig _config = SplashConfig.empty;
  String? _error;

  bool _saving = false;
  double _uploadProgress = 0;

  VideoPlayerController? _previewController;
  bool _previewReady = false;
  bool _previewError = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _previewController?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final config = await SplashConfigService.fetch();
      if (!mounted) return;
      setState(() {
        _config = config;
        _loading = false;
      });
      if (config.hasMedia) {
        _initPreview();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _initPreview() {
    if (_config.isVideo && _config.url.isNotEmpty) {
      _initVideoPreview(_config.url);
    }
  }

  Future<void> _initVideoPreview(String url) async {
    _previewController?.dispose();
    setState(() {
      _previewReady = false;
      _previewError = false;
    });

    try {
      final controller = VideoPlayerController.networkUrl(Uri.parse(url));
      await controller.initialize().timeout(const Duration(seconds: 10));
      controller.setLooping(true);
      controller.play();

      if (!mounted) {
        controller.dispose();
        return;
      }

      setState(() {
        _previewController = controller;
        _previewReady = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _previewError = true);
    }
  }

  Future<void> _pickAndUpload() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      withData: kIsWeb,
      type: FileType.custom,
      allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp', 'gif', 'mp4', 'webm', 'mov'],
    );

    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;
    final ext = file.name.split('.').last.toLowerCase();
    final isVideo = ['mp4', 'webm', 'mov'].contains(ext);
    final mediaType = isVideo ? 'video' : 'image';

    if (!mounted) return;
    setState(() {
      _saving = true;
      _uploadProgress = 0;
      _error = null;
    });

    try {
      final url = await _uploadFile(file);

      final thumbnailUrl = isVideo ? await _fetchThumbnailUrl(url) : '';

      await SplashConfigService.save(
        type: mediaType,
        url: url,
        thumbnailUrl: thumbnailUrl,
      );

      final config = SplashConfig(type: mediaType, url: url, thumbnailUrl: thumbnailUrl);
      await config.saveToPrefs();

      if (!mounted) return;
      setState(() {
        _config = config;
        _saving = false;
        _uploadProgress = 0;
      });

      if (isVideo) {
        _initVideoPreview(url);
      } else {
        setState(() {
          _previewController?.dispose();
          _previewController = null;
          _previewReady = false;
        });
      }

      _showNotice('Splash screen updated successfully!');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _saving = false;
      });
    }
  }

  Future<String> _uploadFile(PlatformFile file) async {
    final uploadUri = await BackendApi.withAuthQuery(
      BackendApi.uri('upload_file_secure.php'),
    );
    final request = http.MultipartRequest('POST', uploadUri);
    request.headers['X-Requested-With'] = 'XMLHttpRequest';
    await BackendApi.applyAuthToMultipart(request);
    request.fields['root'] = 'splash';

    if (kIsWeb) {
      final bytes = file.bytes;
      if (bytes == null) throw Exception('Could not read file bytes.');
      request.files.add(
        http.MultipartFile.fromBytes('file', bytes, filename: file.name),
      );
    } else {
      final path = file.path;
      if (path == null || path.isEmpty) {
        throw Exception('Could not read file path.');
      }
      request.files.add(
        await http.MultipartFile.fromPath('file', path, filename: file.name),
      );
    }

    final streamedResponse = await request.send();
    final responseBody = await streamedResponse.stream.bytesToString();

    if (streamedResponse.statusCode != 200) {
      throw Exception(
        'Upload failed (${streamedResponse.statusCode}): $responseBody',
      );
    }

    final decoded = jsonDecode(responseBody);
    if (decoded is! Map || decoded['success'] != true) {
      throw Exception(
        decoded is Map
            ? (decoded['message'] ?? 'Upload failed')
            : 'Upload failed',
      );
    }

    final url = (decoded['url'] ?? '').toString().trim();
    if (url.isEmpty) throw Exception('Upload succeeded but no URL returned.');
    return url;
  }

  Future<String> _fetchThumbnailUrl(String videoUrl) async {
    try {
      final uri = Uri.parse(videoUrl);
      final base = '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}';
      final segments = uri.pathSegments;
      final nameIndex = segments.lastIndexWhere(
        (s) => s.isNotEmpty && !s.endsWith('/'),
      );
      if (nameIndex < 0) return '';
      final name = segments[nameIndex];
      final baseName = name.contains('.') ? name.substring(0, name.lastIndexOf('.')) : name;
      final dirs = segments.sublist(0, nameIndex);
      return '$base/${dirs.join('/')}/${baseName}_thumb.jpg';
    } catch (_) {
      return '';
    }
  }

  Future<void> _removeSplash() async {
    final ok = await _confirmDialog(
      title: 'Remove Splash',
      message: 'Reset to the default YBS logo on the splash screen?',
      confirmText: 'Remove',
    );
    if (!ok) return;

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      await SplashConfigService.clear();
      await SplashConfig.clearPrefs();

      _previewController?.dispose();
      _previewController = null;
      _previewReady = false;

      if (!mounted) return;
      setState(() {
        _config = SplashConfig.empty;
        _saving = false;
      });

      _showNotice('Splash screen reset to default.');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _saving = false;
      });
    }
  }

  Future<bool> _confirmDialog({
    required String title,
    required String message,
    required String confirmText,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(confirmText),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  void _showNotice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.of(context).size.width >= 760;

    final body = _loading
        ? const Center(child: CircularProgressIndicator())
        : _buildContent(isWide);

    return Scaffold(
      backgroundColor: _appBg,
      appBar: AppBar(
        title: const Text('Splash Screen'),
        backgroundColor: _primaryBlue,
        foregroundColor: Colors.white,
        elevation: 1,
      ),
      body: adminWebBodyFrame(context: context, child: body),
    );
  }

  Widget _buildContent(bool isWide) {
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 720),
        margin: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildInfoCard(),
            const SizedBox(height: 20),
            _buildPreviewArea(isWide),
            const SizedBox(height: 20),
            _buildActions(),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.red.shade200),
                ),
                child: Row(
                  children: [
                    Icon(Icons.error_outline, color: Colors.red.shade700, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _error!,
                        style: TextStyle(color: Colors.red.shade800, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildInfoCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _uiBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline, color: _primaryBlue, size: 20),
              const SizedBox(width: 8),
              Text(
                'Current Configuration',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                  color: _primaryBlue,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _infoRow('Status', _config.hasMedia ? 'Custom media set' : 'Default YBS logo'),
          if (_config.hasMedia) ...[
            _infoRow('Type', _config.isVideo ? 'Video' : 'Image / GIF'),
            _infoRow('URL', _config.url, maxLines: 2),
            if (_config.thumbnailUrl.isNotEmpty)
              _infoRow('Thumbnail', _config.thumbnailUrl, maxLines: 1),
          ],
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value, {int maxLines = 1}) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: TextStyle(
                color: _softText,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 13),
              maxLines: maxLines,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewArea(bool isWide) {
    if (!_config.hasMedia) {
      return Container(
        height: 200,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _uiBorder),
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.school_rounded, size: 48, color: _primaryBlue.withValues(alpha: 0.3)),
              const SizedBox(height: 8),
              Text(
                'Default YBS Logo',
                style: TextStyle(color: _softText, fontSize: 14),
              ),
              const SizedBox(height: 4),
              Text(
                'Upload a media file to customize',
                style: TextStyle(color: _softText.withValues(alpha: 0.7), fontSize: 12),
              ),
            ],
          ),
        ),
      );
    }

    if (_config.isVideo) {
      return _buildVideoPreview(isWide);
    }

    return _buildImagePreview();
  }

  Widget _buildImagePreview() {
    return Container(
      height: 240,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _uiBorder),
        color: Colors.black,
      ),
      clipBehavior: Clip.hardEdge,
      child: Stack(
        fit: StackFit.expand,
        children: [
          CachedNetworkImage(
            imageUrl: _config.url,
            fit: BoxFit.cover,
            errorWidget: (_, _, _) => const Center(
              child: Icon(Icons.broken_image_outlined, color: Colors.white, size: 48),
            ),
          ),
          Positioned(
            left: 8,
            top: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                'PREVIEW',
                style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVideoPreview(bool isWide) {
    final height = isWide ? 400.0 : 260.0;

    if (_previewError) {
      return Container(
        height: height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _uiBorder),
          color: Colors.black,
        ),
        child: const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.broken_image_outlined, color: Colors.white, size: 48),
              SizedBox(height: 8),
              Text('Failed to load preview', style: TextStyle(color: Colors.white)),
            ],
          ),
        ),
      );
    }

    if (!_previewReady || _previewController == null) {
      return Container(
        height: height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _uiBorder),
          color: Colors.black,
        ),
        child: const Center(child: CircularProgressIndicator(color: Colors.white)),
      );
    }

    return Container(
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _uiBorder),
        color: Colors.black,
      ),
      clipBehavior: Clip.hardEdge,
      child: Stack(
        fit: StackFit.expand,
        children: [
          FittedBox(
            fit: BoxFit.cover,
            clipBehavior: Clip.hardEdge,
            child: SizedBox(
              width: _previewController!.value.size.width,
              height: _previewController!.value.size.height,
              child: VideoPlayer(_previewController!),
            ),
          ),
          Positioned(
            left: 8,
            top: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                'PREVIEW',
                style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700),
              ),
            ),
          ),
          Positioned(
            right: 8,
            bottom: 8,
            child: _previewReady
                ? GestureDetector(
                    onTap: () {
                      if (_previewController!.value.isPlaying) {
                        _previewController!.pause();
                      } else {
                        _previewController!.play();
                      }
                      setState(() {});
                    },
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        _previewController!.value.isPlaying
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        color: Colors.white,
                        size: 24,
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Widget _buildActions() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _uiBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Actions',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 15,
              color: _primaryBlue,
            ),
          ),
          const SizedBox(height: 16),
          if (_saving) ...[
            if (_uploadProgress > 0)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Uploading... ${(_uploadProgress * 100).toInt()}%',
                      style: TextStyle(color: _softText, fontSize: 13),
                    ),
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(
                        value: _uploadProgress,
                        minHeight: 6,
                        backgroundColor: _uiBorder,
                        color: _actionOrange,
                      ),
                    ),
                  ],
                ),
              )
            else
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Center(child: CircularProgressIndicator()),
              ),
          ],
          Row(
            children: [
              Expanded(
                child: _actionButton(
                  label: 'Upload New',
                  icon: Icons.upload_rounded,
                  color: _primaryBlue,
                  onTap: _saving ? null : _pickAndUpload,
                ),
              ),
              if (_config.hasMedia) ...[
                const SizedBox(width: 12),
                Expanded(
                  child: _actionButton(
                    label: 'Remove Splash',
                    icon: Icons.delete_outline_rounded,
                    color: Colors.red.shade600,
                    onTap: _saving ? null : _removeSplash,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.amber.shade50,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.lightbulb_outline, color: Colors.amber.shade800, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Supported formats: JPG, PNG, WebP, GIF, MP4, WebM, MOV.\n'
                    'Videos play once with audio, images display full-screen.',
                    style: TextStyle(color: Colors.amber.shade900, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionButton({
    required String label,
    required IconData icon,
    required Color color,
    VoidCallback? onTap,
  }) {
    return Material(
      color: color.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
