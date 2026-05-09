import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../services/backend_api.dart';
import '../shared/app_theme.dart';

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
  final _passC = TextEditingController();
  final _onlineMeetC = TextEditingController();

  bool _saving = false;
  bool _uploadingPhoto = false;

  String _name = 'International Teacher';
  String _photoUrl = '';
  Map<String, dynamic> _sub = <String, dynamic>{};
  List<_SocialRow> _socialRows = <_SocialRow>[];

  static const Map<String, IconData> _iconLibrary = {
    'instagram': Icons.camera_alt_outlined,
    'linkedin': Icons.business_center_outlined,
    'facebook': Icons.thumb_up_alt_outlined,
    'youtube': Icons.play_circle_outline,
    'whatsapp': Icons.chat_bubble_outline,
    'telegram': Icons.send_outlined,
    'globe': Icons.public,
    'tiktok': Icons.music_note_outlined,
    'x': Icons.alternate_email,
  };

  @override
  void initState() {
    super.initState();
    appThemeController.addListener(_onThemeChanged);
    _load();
  }

  void _onThemeChanged() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  void dispose() {
    for (final row in _socialRows) {
      row.controller.dispose();
    }
    appThemeController.removeListener(_onThemeChanged);
    _passC.dispose();
    _onlineMeetC.dispose();
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
    _sub = _asMap(snaps[2].value);

    final first = (u['first_name'] ?? '').toString().trim();
    final last = (u['last_name'] ?? '').toString().trim();
    _name = [first, last].where((e) => e.isNotEmpty).join(' ').trim();
    if (_name.isEmpty) _name = 'International Teacher';

    _photoUrl = (u['profile_photo'] ?? '').toString().trim();
    _onlineMeetC.text = (p['onlineMeetUrl'] ?? '').toString().trim();

    for (final row in _socialRows) {
      row.controller.dispose();
    }
    _socialRows = _readSocialRows(p['socialLinks']);
    if (_socialRows.isEmpty) {
      _socialRows = [
        _SocialRow(iconKey: 'instagram'),
        _SocialRow(iconKey: 'linkedin'),
        _SocialRow(iconKey: 'globe'),
      ];
    }
    if (mounted) setState(() {});
  }

  List<_SocialRow> _readSocialRows(dynamic raw) {
    final rows = <_SocialRow>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is! Map) continue;
        final m = item.map((k, v) => MapEntry(k.toString(), v));
        rows.add(
          _SocialRow(
            iconKey: (m['iconKey'] ?? 'globe').toString(),
            label: (m['label'] ?? '').toString(),
            initialUrl: (m['url'] ?? '').toString(),
          ),
        );
      }
    } else if (raw is String && raw.trim().isNotEmpty) {
      rows.add(_SocialRow(iconKey: 'globe', label: 'Link', initialUrl: raw));
    }
    return rows;
  }

  List<Map<String, String>> _socialPayload() {
    return _socialRows
        .map(
          (r) => {
            'iconKey': r.iconKey,
            'label': r.label.trim().isEmpty ? r.iconKey : r.label.trim(),
            'url': r.controller.text.trim(),
          },
        )
        .where((m) => (m['url'] ?? '').trim().isNotEmpty)
        .toList();
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

    final success = jsonBody['success'] == true || jsonBody['ok'] == true;
    final url = (jsonBody['url'] ?? '').toString();
    if (!success || url.trim().isEmpty) {
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
        'socialLinks': _socialPayload(),
        'onlineMeetUrl': _onlineMeetC.text.trim(),
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

  ({double remainingPct, int daysLeft, Color color, String label})
  _subscriptionState(AppPalette p) {
    final start = DateTime.tryParse((_sub['startsOn'] ?? '').toString());
    final end = DateTime.tryParse((_sub['expiresOn'] ?? '').toString());
    if (start == null || end == null || !end.isAfter(start)) {
      return (remainingPct: 0, daysLeft: 0, color: p.border, label: 'Not set');
    }
    final now = DateTime.now();
    final total = end.difference(start).inSeconds;
    final left = end.difference(now).inSeconds;
    final pct = (left / total).clamp(0, 1).toDouble();
    final days = end.difference(DateTime(now.year, now.month, now.day)).inDays;
    if (left <= 0) {
      return (
        remainingPct: 0,
        daysLeft: 0,
        color: Colors.red.shade700,
        label: 'Expired',
      );
    }
    if (pct <= 0.10) {
      return (
        remainingPct: pct,
        daysLeft: days,
        color: Colors.orange.shade800,
        label: 'Critical',
      );
    }
    if (pct <= 0.30) {
      return (
        remainingPct: pct,
        daysLeft: days,
        color: Colors.amber.shade700,
        label: 'Expiring',
      );
    }
    return (
      remainingPct: pct,
      daysLeft: days,
      color: Colors.green.shade700,
      label: 'Active',
    );
  }

  Future<void> _pickIconForRow(int index) async {
    final p = appThemeController.palette;
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: p.cardBg,
      builder: (ctx) {
        return Stack(
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: Center(
                  child: Opacity(
                    opacity: 0.05,
                    child: Image.asset(
                      'assets/images/ybs_logo.png',
                      width: 220,
                    ),
                  ),
                ),
              ),
            ),
            ListView(
              children: _iconLibrary.entries
                  .map(
                    (e) => ListTile(
                      leading: Icon(e.value),
                      title: Text(e.key),
                      onTap: () => Navigator.of(ctx).pop(e.key),
                    ),
                  )
                  .toList(),
            ),
          ],
        );
      },
    );
    if (picked == null) return;
    setState(() {
      _socialRows[index].iconKey = picked;
      if (_socialRows[index].label.trim().isEmpty) {
        _socialRows[index].label = picked;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = appThemeController.palette;
    final sub = _subscriptionState(p);
    final amount = (_sub['amountPaidUsd'] ?? '').toString();
    final startsOn = (_sub['startsOn'] ?? '').toString();
    final expiresOn = (_sub['expiresOn'] ?? '').toString();
    return Scaffold(
      backgroundColor: p.appBg,
      appBar: AppBar(title: const Text('Profile')),
      body: SafeArea(
        top: false,
        child: Stack(
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: Center(
                  child: Opacity(
                    opacity: 0.055,
                    child: Image.asset(
                      'assets/images/ybs_logo.png',
                      width: 320,
                    ),
                  ),
                ),
              ),
            ),
            ListView(
              padding: EdgeInsets.fromLTRB(
                14,
                14,
                14,
                14 + MediaQuery.of(context).padding.bottom,
              ),
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(24),
                    gradient: LinearGradient(
                      colors: [
                        p.primary,
                        Color.lerp(p.primary, p.accent, 0.35) ?? p.primary,
                      ],
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
                                backgroundColor: p.accent,
                              ),
                              onPressed: _uploadingPhoto
                                  ? null
                                  : _pickAndUploadPhoto,
                              icon: _uploadingPhoto
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Icon(
                                      Icons.camera_alt,
                                      color: Colors.white,
                                    ),
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
                        Row(
                          children: [
                            const Text(
                              'Subscription',
                              style: TextStyle(fontWeight: FontWeight.w900),
                            ),
                            const Spacer(),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: sub.color.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                sub.label,
                                style: TextStyle(
                                  color: sub.color,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text('USD ${amount.isEmpty ? '-' : amount}'),
                        Text(
                          startsOn.isEmpty || expiresOn.isEmpty
                              ? 'No active period'
                              : '$startsOn -> $expiresOn',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 8),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: LinearProgressIndicator(
                            value: sub.remainingPct,
                            minHeight: 10,
                            backgroundColor: p.soft,
                            color: sub.color,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          sub.daysLeft > 0
                              ? '${sub.daysLeft} days remaining'
                              : 'Expired',
                          style: TextStyle(
                            color: sub.color,
                            fontWeight: FontWeight.w700,
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
                          'Social Links',
                          style: TextStyle(fontWeight: FontWeight.w900),
                        ),
                        const SizedBox(height: 10),
                        for (int i = 0; i < _socialRows.length; i++)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Row(
                              children: [
                                InkWell(
                                  onTap: () => _pickIconForRow(i),
                                  child: Container(
                                    width: 44,
                                    height: 44,
                                    decoration: BoxDecoration(
                                      color: p.soft,
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Icon(
                                      _iconLibrary[_socialRows[i].iconKey] ??
                                          Icons.public,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: TextField(
                                    controller: _socialRows[i].controller,
                                    decoration: InputDecoration(
                                      border: const OutlineInputBorder(),
                                      labelText: _socialRows[i].label.isEmpty
                                          ? 'URL'
                                          : _socialRows[i].label,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        OutlinedButton.icon(
                          onPressed: () {
                            setState(() {
                              _socialRows.add(
                                _SocialRow(iconKey: 'globe', label: 'Link'),
                              );
                            });
                          },
                          icon: const Icon(Icons.add_link_rounded),
                          label: const Text('Add another input'),
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
                          'Online Meet',
                          style: TextStyle(fontWeight: FontWeight.w900),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _onlineMeetC,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            labelText: 'Online meet URL',
                            hintText: 'https://meet.google.com/...',
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
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  style: FilledButton.styleFrom(
                    backgroundColor: p.primary,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: Text(_saving ? 'Saving...' : 'Save Profile'),
                ),
              ],
            ),
          ],
        ),
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

class _SocialRow {
  _SocialRow({required this.iconKey, this.label = '', String initialUrl = ''})
    : controller = TextEditingController(text: initialUrl);

  String iconKey;
  String label;
  final TextEditingController controller;
}
