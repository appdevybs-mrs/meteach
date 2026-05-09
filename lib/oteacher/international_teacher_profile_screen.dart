import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../services/backend_api.dart';

class InternationalTeacherProfileScreen extends StatefulWidget {
  const InternationalTeacherProfileScreen({super.key, required this.uid});
  final String uid;

  @override
  State<InternationalTeacherProfileScreen> createState() =>
      _InternationalTeacherProfileScreenState();
}

class _InternationalTeacherProfileScreenState
    extends State<InternationalTeacherProfileScreen> {
  final _db = FirebaseDatabase.instance.ref();
  final _socialC = TextEditingController();
  final _passC = TextEditingController();
  bool _saving = false;
  bool _uploadingPhoto = false;

  String _name = 'International Teacher';
  String _photoUrl = '';
  String _subText = 'Subscription not set';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _socialC.dispose();
    _passC.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final snaps = await Future.wait([
      _db.child('users/${widget.uid}').get(),
      _db.child('international_teacher_profile/${widget.uid}').get(),
      _db.child('international_teacher_subscription/${widget.uid}').get(),
    ]);
    final u = _asMap(snaps[0].value);
    final p = _asMap(snaps[1].value);
    final s = _asMap(snaps[2].value);

    final first = (u['first_name'] ?? '').toString().trim();
    final last = (u['last_name'] ?? '').toString().trim();
    _name = [first, last].where((e) => e.isNotEmpty).join(' ').trim();
    if (_name.isEmpty) _name = 'International Teacher';

    _photoUrl = (u['profile_photo'] ?? '').toString().trim();
    _socialC.text = (p['socialLinks'] ?? '').toString().trim();

    final expiresOn = (s['expiresOn'] ?? '').toString().trim();
    final amount = (s['amountPaidUsd'] ?? '').toString().trim();
    _subText = expiresOn.isEmpty
        ? 'Subscription not set'
        : 'USD ${amount.isEmpty ? '-' : amount} • Expires on $expiresOn';

    if (mounted) setState(() {});
  }

  Future<String> _uploadPlatformFile(PlatformFile file) async {
    final uploadUri = await BackendApi.withAuthQuery(
      BackendApi.uri('upload_secure.php'),
    );
    final request = http.MultipartRequest('POST', uploadUri);
    await BackendApi.applyAuthToMultipart(request);

    if (kIsWeb) {
      final bytes = file.bytes;
      if (bytes == null) {
        throw Exception('Selected file bytes are unavailable on web.');
      }
      request.files.add(
        http.MultipartFile.fromBytes('file', bytes, filename: file.name),
      );
    } else {
      final path = file.path;
      if (path == null || path.isEmpty) {
        throw Exception('Selected file path is invalid.');
      }
      request.files.add(await http.MultipartFile.fromPath('file', path));
    }

    final response = await request.send();
    final body = await response.stream.bytesToString();
    Map<String, dynamic> jsonBody = <String, dynamic>{};
    try {
      jsonBody = jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {}

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final message =
          (jsonBody['error'] ?? 'Upload failed (${response.statusCode})')
              .toString();
      throw Exception(message);
    }

    final ok = jsonBody['ok'] == true;
    final url = (jsonBody['url'] ?? '').toString();
    if (!ok || url.trim().isEmpty) {
      throw Exception((jsonBody['error'] ?? 'Upload failed').toString());
    }
    return url.trim();
  }

  Future<void> _pickAndUploadPhoto() async {
    if (_uploadingPhoto || _saving) return;
    setState(() => _uploadingPhoto = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: false,
        type: FileType.image,
        withData: kIsWeb,
      );
      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      final url = await _uploadPlatformFile(file);

      await _db.child('users/${widget.uid}').update({
        'profile_photo': url,
        'profile_photos': [url],
        'updatedAt': ServerValue.timestamp,
      });

      _photoUrl = url;
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Profile photo updated.')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Photo upload failed: $e')));
    } finally {
      if (mounted) setState(() => _uploadingPhoto = false);
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await _db.child('international_teacher_profile/${widget.uid}').update({
        'socialLinks': _socialC.text.trim(),
        'updatedAt': ServerValue.timestamp,
      });

      final newPass = _passC.text.trim();
      if (newPass.isNotEmpty) {
        final user = FirebaseAuth.instance.currentUser;
        if (user != null && user.uid == widget.uid) {
          await user.updatePassword(newPass);
        }
      }
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Profile updated.')));
      _passC.clear();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Update failed: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF3F6FA),
      appBar: AppBar(title: const Text('Profile')),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              gradient: const LinearGradient(
                colors: [Color(0xFF0D2B45), Color(0xFF284F70)],
              ),
            ),
            child: Row(
              children: [
                Stack(
                  children: [
                    CircleAvatar(
                      radius: 34,
                      backgroundColor: Colors.white24,
                      backgroundImage: _photoUrl.isEmpty
                          ? null
                          : NetworkImage(_photoUrl),
                      child: _photoUrl.isEmpty
                          ? const Icon(
                              Icons.person,
                              color: Colors.white,
                              size: 34,
                            )
                          : null,
                    ),
                    Positioned(
                      right: -2,
                      bottom: -2,
                      child: IconButton(
                        style: IconButton.styleFrom(
                          backgroundColor: const Color(0xFFBF6A3D),
                        ),
                        onPressed: _uploadingPhoto ? null : _pickAndUploadPhoto,
                        icon: _uploadingPhoto
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.camera_alt, color: Colors.white),
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _name,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w900,
                          fontSize: 20,
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'International Teacher',
                        style: TextStyle(
                          color: Colors.white70,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Card(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Social Links',
                    style: TextStyle(fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _socialC,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      hintText: 'Instagram: ...\nLinkedIn: ...\nWebsite: ...',
                    ),
                  ),
                ],
              ),
            ),
          ),
          Card(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Security',
                    style: TextStyle(fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _passC,
                    obscureText: true,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: 'Change Password',
                    ),
                  ),
                ],
              ),
            ),
          ),
          Card(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            child: ListTile(
              leading: const Icon(Icons.workspace_premium_outlined),
              title: const Text('Subscription'),
              subtitle: Text(_subText),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _saving ? null : _save,
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF0D2B45),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            child: Text(_saving ? 'Saving...' : 'Save Profile'),
          ),
        ],
      ),
    );
  }

  Map<String, dynamic> _asMap(dynamic raw) {
    if (raw is Map) {
      return raw.map((k, v) => MapEntry(k.toString(), v));
    }
    return <String, dynamic>{};
  }
}
